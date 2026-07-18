;;;; tests/pbt/edit-engine-modes.lisp -- SPEC-VK VK-4 mode acceptance.
;;;;
;;;; The kernel-backed edit engine (src/buffer/internal/buffer-insert.lisp) has
;;;; three modes; this suite exercises the two checking modes end to end:
;;;;
;;;;   :paranoid    -- the V0-5 baseline fuzz (10k scripted steps, undo/redo,
;;;;                   multi-point marker relocation) re-run with the per-edit
;;;;                   certified wf-buffer assertion on the affected region; any
;;;;                   `corruption-warning' fails the property.  A teeth test
;;;;                   corrupts a registered point and asserts the next edit is
;;;;                   flagged.
;;;;
;;;;   :conformance -- every mutation is additionally mirrored through the FULL
;;;;                   kernel (k-insert / k-delete) on the FULL buffer model and
;;;;                   compared field-for-field inside the engine; a mismatch
;;;;                   signals `edit-engine-conformance-error', which the
;;;;                   harness treats as a property failure.  This is the
;;;;                   locality-boundary pin: any mis-collected region, missed
;;;;                   tail renumber or bad materialization diverges from the
;;;;                   full-model mirror by construction.
;;;;
;;;; Script generation/interpretation is shared with the V0-5 baseline fuzz
;;;; (tests/pbt/baseline-fuzz.lisp) so the exercised surface is identical.

(defpackage :lem-tests/pbt/edit-engine-modes
  (:use :cl
        :rove
        :lem-tests/pbt/harness))
(in-package :lem-tests/pbt/edit-engine-modes)

(defun run-fuzz-script (script)
  "Run SCRIPT through the baseline-fuzz interpreter, additionally treating any
`corruption-warning' raised during the run (the :paranoid reporting channel) as
a failure. Returns T iff the script ran clean."
  (let ((warned nil))
    (handler-bind ((lem/buffer/internal:corruption-warning
                     (lambda (w)
                       (setf warned t)
                       (muffle-warning w))))
      (and (lem-tests/pbt/baseline-fuzz::run-edit-script script)
           (not warned)))))

;;; VK-4 acceptance: the 10k-step V0-5 fuzz green in :paranoid mode -- the
;;; certified region wf-buffer assertion holds after every mutation.
(deftest baseline-fuzz-paranoid-mode
  (let ((lem/buffer/internal:*edit-engine-mode* :paranoid)
        (*num-tests* 200))
    (for-all ((script (lem-tests/pbt/baseline-fuzz::gen-fuzz-script
                       :min-ops 40 :max-ops 60)))
      (run-fuzz-script script))))

;;; Teeth: a deliberately corrupted registered point (charpos far out of the
;;; line) must make the very next edit's region assertion fire.
(deftest paranoid-check-has-teeth
  (let* ((lem/buffer/internal:*edit-engine-mode* :paranoid)
         (buffer (lem:make-buffer "pbt-vk4-teeth" :temporary t))
         (point (lem:buffer-point buffer))
         (extra (lem:copy-point point :left-inserting))
         (warned nil))
    (unwind-protect
         (handler-bind ((lem/buffer/internal:corruption-warning
                          (lambda (w)
                            (setf warned t)
                            (muffle-warning w))))
           (lem:insert-string point "hello")
           (ok (not warned) "a sane edit passes the paranoid region check")
           (setf (lem:point-charpos extra) 99)
           (lem:insert-string point "x")
           (ok warned "an edit on a line with a corrupted point is flagged"))
      (ignore-errors (lem:delete-point extra))
      (ignore-errors (lem:delete-buffer buffer)))))

;;; VK-4 locality pin: fuzz with every mutation mirrored through the full
;;; kernel on the full model and compared field-for-field.
(deftest conformance-mode-fuzz
  (let ((lem/buffer/internal:*edit-engine-mode* :conformance)
        (*num-tests* 150))
    (for-all ((script (lem-tests/pbt/baseline-fuzz::gen-fuzz-script
                       :min-ops 30 :max-ops 50)))
      (lem-tests/pbt/baseline-fuzz::run-edit-script script))))
