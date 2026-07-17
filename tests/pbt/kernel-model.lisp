;;;; tests/pbt/kernel-model.lisp -- SPEC-VK VK-1 in-image acceptance.
;;;;
;;;; Pins the certified `wf-buffer' (verified/buffer-model.lisp, loaded through
;;;; verified/shim.lisp) against production from BOTH sides:
;;;;
;;;;   (a) production -> model: over PBT-generated production buffers, whenever
;;;;       `check-buffer-corruption' passes, the model built by `buffer->model'
;;;;       must satisfy `wf-buffer'.  Production buffers are always well-formed,
;;;;       so this is the strong direction: wf-buffer must ACCEPT everything the
;;;;       production predicate accepts.  The mapper also asserts production's
;;;;       cached `buffer-nlines' equals (len model-lines), pinning the "no
;;;;       nlines field" model decision.
;;;;
;;;;   (b) corrupted model -> reject: hand-mutated models (out-of-range charpos,
;;;;       wrong end-point, duplicate ids, codepoint 10 inside a line, missing
;;;;       distinguished id, invalid kind) must make `wf-buffer' FALSE.  wf-buffer
;;;;       must REJECT the structural corruptions check-buffer-corruption catches.
;;;;
;;;; The converter lives here in the test package (SPEC-VK VK-1: it is NOT a
;;;; book); it reaches into production internals deliberately to introspect the
;;;; live buffer.  Codepoint conversion (char-code) happens here, never inside a
;;;; book (ACL2 characters are 8-bit; kernel text is codepoint lists).

(defpackage :lem-tests/pbt/kernel-model
  (:use :cl
        :rove
        :lem-tests/pbt/harness))
(in-package :lem-tests/pbt/kernel-model)

;;; ------------------------------------------------------------------
;;; Kernel loading (shim + certified book)
;;; ------------------------------------------------------------------

(defun repo-root ()
  (asdf:system-source-directory :lem-tests))

(defun ensure-kernel-loaded ()
  "Load the dual-load shim and the VK-1 buffer-model book into this image once.
Idempotent; muffles redefinition warnings."
  (handler-bind ((warning #'muffle-warning))
    (unless (find-package "LEM/KERNEL")
      (load (merge-pathnames "verified/shim.lisp" (repo-root))))
    (let ((wf (find-symbol "WF-BUFFER" "LEM/KERNEL")))
      (when (or (null wf) (not (fboundp wf)))
        (funcall (find-symbol "LOAD-VERIFIED-BOOK" "LEM/KERNEL") "buffer-model")))))

(defun kwf (model)
  "Call the certified kernel `wf-buffer' on MODEL through the :lem/kernel surface."
  (funcall (find-symbol "WF-BUFFER" "LEM/KERNEL") model))

(defun k-empty-buffer ()
  "The certified canonical empty-buffer model, through the :lem/kernel surface."
  (funcall (find-symbol "EMPTY-BUFFER" "LEM/KERNEL")))

;;; ------------------------------------------------------------------
;;; buffer->model converter (production buffer -> kernel model)
;;; ------------------------------------------------------------------

(defun point->model (id point)
  "Model tuple (id linum charpos kind) for a live production POINT."
  (list id
        (lem/buffer/internal::point-linum point)
        (lem/buffer/internal:point-charpos point)
        (lem/buffer/internal:point-kind point)))

(defun line->codepoints (line)
  "Codepoint list of a production LINE's text (no embedded newline: lines never
hold one)."
  (map 'list #'char-code (lem/buffer/line:line-string line)))

(defun buffer->model (buffer)
  "Convert a live production BUFFER to the VK-1 model (list lines points tick).

Lines are codepoint lists in buffer order.  Points are the three distinguished
points with fixed ids -- 0=start, 1=end, 2=buffer-point -- followed by every
other registered point in creation order (ids 3, 4, ...).  Production's
`buffer-points' is in reverse creation order (push-prepended), so reversing it
recovers creation order.  Temporary points are never registered, so they never
appear.  Tick is 0 (VK-1 only requires it be an integer)."
  (let* ((start (lem/buffer/internal:buffer-start-point buffer))
         (end (lem/buffer/internal:buffer-end-point buffer))
         (curp (lem/buffer/internal:buffer-point buffer))
         (creation-order (reverse (lem/buffer/internal::buffer-points buffer)))
         (extras (remove-if (lambda (p) (or (eq p start) (eq p end) (eq p curp)))
                            creation-order))
         (lines (loop :for line := (lem/buffer/internal:point-line start)
                        :then (lem/buffer/line:line-next line)
                      :while line
                      :collect (line->codepoints line)))
         (points (append (list (point->model 0 start)
                               (point->model 1 end)
                               (point->model 2 curp))
                         (loop :for p :in extras
                               :for id :from 3
                               :collect (point->model id p)))))
    (list lines points 0)))

;;; ------------------------------------------------------------------
;;; Corruption oracle
;;; ------------------------------------------------------------------

(defun buffer-corrupt-p (buffer)
  "T when BUFFER trips `check-buffer-corruption', NIL when well-formed."
  (handler-case
      (progn (lem/buffer/internal:check-buffer-corruption buffer) nil)
    (lem/buffer/internal:corruption-warning () t)))

;;; ------------------------------------------------------------------
;;; Edit-script generator + interpreter (production buffer, kept alive)
;;; ------------------------------------------------------------------

(defun gen-insert-string (max-length)
  "Short Unicode strings to insert; ~40% contain a newline so multi-line splits
and cross-line marker relocation are exercised."
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

(defun gen-op (&key (max-pos 120) (max-count 8) (max-insert 6))
  "A single edit operation as data (positions/indices mapped into range by the
interpreter, so no draw is ever out of bounds)."
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

(defun gen-script (&key (min-ops 30) (max-ops 50))
  (gen-list (gen-op) :min-length min-ops :max-length max-ops))

(defun buffer-char-count (buffer)
  (1- (lem:position-at-point (lem/buffer/internal:buffer-end-point buffer))))

(defun clamp-position (buffer raw)
  (1+ (mod raw (1+ (buffer-char-count buffer)))))

(defun run-script-checking-wf (script)
  "Run SCRIPT against a fresh production buffer.  After every step assert the
VK-1 pin: (check-buffer-corruption passes) => (wf-buffer holds of the model),
and production's cached nlines equals the model's line count.  Return T iff the
pin held at every step, NIL otherwise."
  (let* ((buffer (lem:make-buffer "pbt-vk1" :temporary t))
         (point (lem/buffer/internal:buffer-point buffer))
         (extra '())
         (ok t))
    (flet ((check ()
             (let* ((corrupt (buffer-corrupt-p buffer))
                    (model (buffer->model buffer)))
               ;; The pin: whenever production says well-formed, the kernel must
               ;; agree, AND the derived nlines must match the cached field.
               (unless (or corrupt
                           (and (kwf model)
                                (= (lem/buffer/internal:buffer-nlines buffer)
                                   (length (first model)))))
                 (setf ok nil)))))
      (unwind-protect
           (block done
             (check)
             (unless ok (return-from done nil))
             (dolist (op script)
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
                 (lem/buffer/errors:editor-error () nil))
               (check)
               (unless ok (return-from done nil)))
             t)
        (dolist (p extra) (ignore-errors (lem:delete-point p)))
        (ignore-errors (lem:delete-buffer buffer))))))

;;; ------------------------------------------------------------------
;;; A hand-built valid model + corrupting mutations (direction b)
;;; ------------------------------------------------------------------

(defun valid-model ()
  "A valid two-line model: lines \"ab\" / \"cde\", start/end/point present."
  (list (list (list 97 98) (list 99 100 101))   ; "ab" "cde"
        (list (list 0 1 0 :right-inserting)      ; start (1,0)
              (list 1 2 3 :left-inserting)       ; end   (2,3) = end of line 2
              (list 2 1 1 :left-inserting))      ; point (1,1)
        0))

;;; ------------------------------------------------------------------
;;; Tests
;;; ------------------------------------------------------------------

(deftest kernel-wf-accepts-canonical-and-valid
  (ensure-kernel-loaded)
  (ok (kwf (k-empty-buffer))
      "certified empty-buffer model is well-formed in-image")
  (ok (kwf (valid-model))
      "a hand-built valid two-line model is well-formed")
  ;; A fresh production buffer converts to a well-formed model.
  (let ((buffer (lem:make-buffer "pbt-vk1-fresh" :temporary t)))
    (unwind-protect
         (ok (kwf (buffer->model buffer))
             "fresh production buffer converts to a well-formed model")
      (ignore-errors (lem:delete-buffer buffer)))))

(deftest kernel-wf-rejects-corruptions
  (ensure-kernel-loaded)
  ;; Sanity: the base is accepted, so each rejection below is caused by the
  ;; mutation, not a broken base.
  (ok (kwf (valid-model)) "base model accepted (teeth)")
  ;; out-of-range charpos: point 2 charpos 5 > line-1 length 2.
  (ng (kwf (list (first (valid-model))
                 (list (list 0 1 0 :right-inserting)
                       (list 1 2 3 :left-inserting)
                       (list 2 1 5 :left-inserting))
                 0))
      "charpos past end of line is rejected")
  ;; wrong end-point charpos: 2 /= length of last line (3).
  (ng (kwf (list (first (valid-model))
                 (list (list 0 1 0 :right-inserting)
                       (list 1 2 2 :left-inserting)
                       (list 2 1 1 :left-inserting))
                 0))
      "end-point not at end of last line is rejected")
  ;; wrong end-point linum: end on line 1, not the last line.
  (ng (kwf (list (first (valid-model))
                 (list (list 0 1 0 :right-inserting)
                       (list 1 1 0 :left-inserting)
                       (list 2 1 1 :left-inserting))
                 0))
      "end-point not on the last line is rejected")
  ;; duplicate ids: two points share id 2.
  (ng (kwf (list (first (valid-model))
                 (list (list 0 1 0 :right-inserting)
                       (list 1 2 3 :left-inserting)
                       (list 2 1 1 :left-inserting)
                       (list 2 1 0 :left-inserting))
                 0))
      "duplicate point ids are rejected")
  ;; codepoint 10 (LF) inside a line.
  (ng (kwf (list (list (list 97 10 98) (list 99 100 101))
                 (list (list 0 1 0 :right-inserting)
                       (list 1 2 3 :left-inserting)
                       (list 2 1 1 :left-inserting))
                 0))
      "a newline codepoint inside a line is rejected")
  ;; missing distinguished id: no buffer-point (id 2).
  (ng (kwf (list (first (valid-model))
                 (list (list 0 1 0 :right-inserting)
                       (list 1 2 3 :left-inserting))
                 0))
      "missing buffer-point (id 2) is rejected")
  ;; invalid kind: :temporary is not a modelled kind.
  (ng (kwf (list (first (valid-model))
                 (list (list 0 1 0 :right-inserting)
                       (list 1 2 3 :left-inserting)
                       (list 2 1 1 :temporary))
                 0))
      "an invalid point kind is rejected")
  ;; a point before start-point (breaks the point<= ordering invariant).
  (ng (kwf (list (first (valid-model))
                 (list (list 0 1 1 :right-inserting)   ; start pushed to (1,1)
                       (list 1 2 3 :left-inserting)
                       (list 2 1 0 :left-inserting))   ; point (1,0) < start
                 0))
      "a point ordered before start-point is rejected")
  ;; empty line list (production always has >= 1 line).
  (ng (kwf (list nil
                 (list (list 0 1 0 :right-inserting)
                       (list 1 1 0 :left-inserting)
                       (list 2 1 0 :left-inserting))
                 0))
      "a buffer with zero lines is rejected")
  ;; non-integer tick.
  (ng (kwf (list (first (valid-model))
                 (list (list 0 1 0 :right-inserting)
                       (list 1 2 3 :left-inserting)
                       (list 2 1 1 :left-inserting))
                 :not-an-integer))
      "a non-integer tick is rejected"))

;;; VK-1 acceptance: over PBT-generated production buffers, wf-buffer(model) holds
;;; whenever check-buffer-corruption passes (and nlines agrees), after every step.
(deftest kernel-wf-vs-check-buffer-corruption
  (ensure-kernel-loaded)
  (let ((*num-tests* 200))
    (for-all ((script (gen-script :min-ops 30 :max-ops 50)))
      (run-script-checking-wf script))))
