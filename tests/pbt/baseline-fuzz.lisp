(defpackage :lem-tests/pbt/baseline-fuzz
  (:use :cl
        :rove
        :lem-tests/pbt/harness))
(in-package :lem-tests/pbt/baseline-fuzz)

;;; SPEC-VK V0-5 — baseline conformance fuzz.
;;;
;;; Random edit scripts are run against fresh PRODUCTION buffers through the
;;; exported buffer API (`insert-string', `delete-character', point movement,
;;; `buffer-undo'/`buffer-redo', undo boundaries) and the well-formedness
;;; predicate `check-buffer-corruption' is asserted after EVERY step. Multi-point
;;; scenarios (extra :left-inserting / :right-inserting points that are
;;; registered, moved and deleted) exercise marker relocation, the riskiest
;;; invariant. This is the pre-kernel anchor: it must be green before any kernel
;;; rewrite begins, and any corruption it surfaces is a production bug to fix.
;;;
;;; The V0-4 PBT harness drives the property: on failure it shrinks the offending
;;; script and prints a reproducing seed (settable via LEM_PBT_SEED).

;;; ------------------------------------------------------------------
;;; Corruption detection
;;; ------------------------------------------------------------------

(defun buffer-corrupt-p (buffer)
  "Return T when BUFFER violates any structural invariant checked by
`check-buffer-corruption', NIL when it is well-formed. The predicate reports
violations by signalling `corruption-warning'; this converts that into a value."
  (handler-case
      (progn (lem/buffer/internal:check-buffer-corruption buffer) nil)
    (lem/buffer/internal:corruption-warning () t)))

;;; ------------------------------------------------------------------
;;; Edit-operation generator (data-only ops, shrunk by script minimisation)
;;; ------------------------------------------------------------------

(defun gen-insert-string (max-length)
  "A generator of short strings to insert. Reuses the harness Unicode string
generator (multibyte / combining / emoji) and embeds a newline in ~40% of draws
so multi-line splits and marker relocation across lines are exercised."
  (let ((base (gen-string :max-length max-length)))
    (make-generator
     :sample (lambda (rng)
               (let ((s (draw base rng)))
                 (if (< (rng-below rng 100) 40)
                     (let ((i (rng-below rng (1+ (length s)))))
                       (concatenate 'string (subseq s 0 i)
                                    (string #\Newline)
                                    (subseq s i)))
                     s)))
     :shrink (generator-shrink base))))

(defun gen-fuzz-op (&key (max-pos 200) (max-count 8) (max-insert 6))
  "A generator of a single edit operation, encoded as data. One of:
  (:insert POS STRING) (:delete POS COUNT) (:move POS)
  (:add-point KIND POS) (:move-point IDX POS) (:del-point IDX)
  (:undo) (:redo) (:boundary)
POS / IDX are raw integers mapped into range by the interpreter, so no draw ever
produces an out-of-bounds request."
  (let ((string-gen (gen-insert-string max-insert)))
    (make-generator
     :sample (lambda (rng)
               (ecase (rng-below rng 9)
                 (0 (list :insert (rng-below rng max-pos) (draw string-gen rng)))
                 (1 (list :delete (rng-below rng max-pos) (rng-range rng 1 max-count)))
                 (2 (list :move (rng-below rng max-pos)))
                 (3 (list :add-point
                          (if (rng-boolean rng) :left-inserting :right-inserting)
                          (rng-below rng max-pos)))
                 (4 (list :move-point (rng-below rng 8) (rng-below rng max-pos)))
                 (5 (list :del-point (rng-below rng 8)))
                 (6 (list :undo))
                 (7 (list :redo))
                 (8 (list :boundary)))))))

(defun gen-fuzz-script (&key (min-ops 40) (max-ops 60))
  "A generator of edit scripts: lists of [MIN-OPS, MAX-OPS] edit operations.
Shrinking drops and halves the op list, minimising a failing script to a small
counterexample."
  (gen-list (gen-fuzz-op) :min-length min-ops :max-length max-ops))

;;; ------------------------------------------------------------------
;;; Interpreter: run a script against a fresh production buffer
;;; ------------------------------------------------------------------

(defun buffer-char-count (buffer)
  "Number of characters currently in BUFFER (its size in absolute offsets)."
  (1- (lem:position-at-point (lem:buffer-end-point buffer))))

(defun clamp-position (buffer raw)
  "Map raw integer RAW to a valid 1-based buffer position in [1, size+1]."
  (1+ (mod raw (1+ (buffer-char-count buffer)))))

(defun run-edit-script (script)
  "Run edit SCRIPT against a fresh temporary buffer, asserting the buffer stays
structurally well-formed after every step. Return T when it does, NIL on the
first `check-buffer-corruption' violation. Out-of-range requests are clamped and
the (defensive) production ops never signal for them, so a NIL result means a
genuine structural corruption, not a rejected edit."
  (let* ((buffer (lem:make-buffer "pbt-baseline-fuzz" :temporary t))
         (point (lem:buffer-point buffer))
         (extra '()))
    (unwind-protect
         (block done
           (when (buffer-corrupt-p buffer)
             (return-from done nil))
           (dolist (op script t)
             (handler-case
                 (ecase (first op)
                   (:insert
                    (lem:move-to-position point (clamp-position buffer (second op)))
                    (lem:insert-string point (third op)))
                   (:delete
                    (lem:move-to-position point (clamp-position buffer (second op)))
                    (lem:delete-character point (third op)))
                   (:move
                    (lem:move-to-position point (clamp-position buffer (second op))))
                   (:add-point
                    (let ((p (lem:copy-point point (second op))))
                      (lem:move-to-position p (clamp-position buffer (third op)))
                      (push p extra)))
                   (:move-point
                    (when extra
                      (lem:move-to-position
                       (nth (mod (second op) (length extra)) extra)
                       (clamp-position buffer (third op)))))
                   (:del-point
                    (when extra
                      (let* ((i (mod (second op) (length extra)))
                             (p (nth i extra)))
                        (setf extra (remove p extra :count 1 :test #'eq))
                        (lem:delete-point p))))
                   (:undo (lem:buffer-undo point))
                   (:redo (lem:buffer-redo point))
                   (:boundary (lem:buffer-undo-boundary buffer)))
               ;; A user-facing rejection (e.g. read-only) is not corruption; the
               ;; invariant check below still runs on the unchanged buffer.
               (lem/buffer/errors:editor-error () nil))
             (when (buffer-corrupt-p buffer)
               (return-from done nil))))
      (dolist (p extra)
        (ignore-errors (lem:delete-point p)))
      (ignore-errors (lem:delete-buffer buffer)))))

;;; ------------------------------------------------------------------
;;; Tests
;;; ------------------------------------------------------------------

;;; Teeth check: the detection mechanism must actually flag a broken buffer, so
;;; a green fuzz run is meaningful rather than vacuous.
(deftest corruption-detection-has-teeth
  (let* ((buffer (lem:make-buffer "pbt-teeth" :temporary t))
         (point (lem:buffer-point buffer)))
    (lem:insert-string point "abc")
    (ok (not (buffer-corrupt-p buffer)) "a well-formed buffer is not flagged")
    ;; Break the end-point invariant (charpos = length of the last line).
    (setf (lem:point-charpos (lem:buffer-end-point buffer)) 99)
    (ok (buffer-corrupt-p buffer) "a structurally corrupt buffer is detected")))

;;; V0-5 acceptance: ~10k scripted edit steps (200 scripts x ~50 ops) with
;;; `check-buffer-corruption' asserted after every step, all green.
(deftest baseline-conformance-fuzz
  (let ((*num-tests* 200))
    (for-all ((script (gen-fuzz-script :min-ops 40 :max-ops 60)))
      (run-edit-script script))))
