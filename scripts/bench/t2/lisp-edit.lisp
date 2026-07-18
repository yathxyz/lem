;;;; lisp-edit.lisp -- T2 workload: syntax-scanned structural Lisp editing (PF-5).
;;;;
;;;; The pinned `lisp-500k' corpus in a real syntax-scanned Lisp buffer (the
;;;; lem-lisp-syntax paren/string/comment syntax table for structural motion +
;;;; the lem-lisp-mode tmlanguage grammar for highlight attributes, both loaded
;;;; directly to avoid lem-lisp-mode's heavy transitive deps -- the same
;;;; headless-grammar trick the T1 `syntax' entry and the T2 `scroll' workload
;;;; use).  RUN drives lem-core's structural + indent machinery (SPEC-PERF PF-5
;;;; lisp-edit row):
;;;;   * `forward-sexp' / `backward-sexp' motion sweeps (the syntax-table
;;;;     `form-offset' / `scan-lists' path),
;;;;   * indent-heavy editing: `newline-and-indent' at nesting points, each
;;;;     followed by a re-scan of the touched region (`syntax-scan-region').
;;;;
;;;; Indentation uses lem-core's `calc-indent-default' (the default
;;;; `calc-indent-function'); the lisp-specific `calc-indent' lives in
;;;; lem-lisp-syntax, whose load pulls micros/usocket, which the `:lem/core'
;;;; bench image deliberately does not carry -- and the task calls for
;;;; "lem-core's syntax/indent machinery" specifically.
;;;;
;;;; Replayability: SETUP inserts the corpus with undo DISABLED (so the corpus
;;;; is never on the undo stack), then enables undo.  The sexp sweeps are
;;;; read-only; the indent edits are undone at the end of RUN by draining the
;;;; undo stack (which stops at the corpus base, since the corpus insert was not
;;;; recorded).  RUN resets the cursor at entry, so every execution replays the
;;;; identical session and restores the identical text.

(in-package :cl-user)

(defparameter *bench-t2-lisp-edit-sexp-steps* 100
  "forward-sexp steps in the motion sweep (and backward-sexp steps back).
Kept modest because `backward-sexp' (form-offset with a negative count) is
~100x costlier per call than `forward-sexp' over dense real Lisp -- it dominates
the sweep, so the count is sized for a bounded, gate-stable window rather than
raw motion volume.")

(defparameter *bench-t2-lisp-edit-sexp-render-every* 20
  "Render once per this many sexp motions (keeps the sweep a bounded frame count).")

(defparameter *bench-t2-lisp-edit-indent-edits* 60
  "newline-and-indent edits performed at nesting points, each re-scanned + rendered.")

(defparameter *bench-t2-lisp-edit-rescan-lines* 4
  "Lines above/below an edit that are re-syntax-scanned after it.")

(defun bench-t2-lisp-edit-ensure-machinery ()
  "Load the lisp syntax table and the lisp-mode tmlanguage grammar once (guarded
so repeated workload setups -- and the scroll workload -- do not reload them),
and return `make-tmlanguage-lisp'."
  (unless (find-symbol "*SYNTAX-TABLE*" :lem-lisp-syntax.syntax-table)
    (load (merge-pathnames "extensions/lisp-syntax/syntax-table.lisp" (bench-repo-root))))
  (unless (find-symbol "MAKE-TMLANGUAGE-LISP" :lem-lisp-mode/grammar)
    (load (merge-pathnames "extensions/lisp-mode/grammar.lisp" (bench-repo-root))))
  (values (symbol-value (find-symbol "*SYNTAX-TABLE*" :lem-lisp-syntax.syntax-table))
          (find-symbol "MAKE-TMLANGUAGE-LISP" :lem-lisp-mode/grammar)))

(defun bench-t2-lisp-edit-setup ()
  "Build the syntax-scanned lisp-500k buffer once (syntax table + grammar +
full scan); corpus inserted with undo disabled, then undo enabled for the edits."
  (multiple-value-bind (syntax-table make-tmlanguage-lisp)
      (bench-t2-lisp-edit-ensure-machinery)
    (let ((buffer (lem:make-buffer "bench-t2-lisp-edit" :temporary t
                                                        :enable-undo-p nil
                                                        :syntax-table syntax-table)))
      (lem:set-syntax-parser syntax-table (funcall make-tmlanguage-lisp))
      (lem:insert-string (lem:buffer-point buffer)
                         (uiop:read-file-string (bench-ensure-corpus :lisp-500k)))
      (lem:buffer-enable-undo buffer)
      (setf (lem:variable-value 'lem:enable-syntax-highlight :buffer buffer) t)
      (lem:syntax-scan-region (lem:buffer-start-point buffer)
                              (lem:buffer-end-point buffer))
      buffer)))

(defun bench-t2-lisp-edit-sexp-sweep ()
  "Sweep forward by sexp then back over the current buffer, rendering
periodically.  `forward-sexp'/`backward-sexp' operate on the current point;
`no-errors' t makes them return NIL (rather than signalling) at a scan
boundary, so the sweep never crashes on a malformed region."
  (lem:move-to-beginning-of-buffer)
  (loop :for i :from 1 :to *bench-t2-lisp-edit-sexp-steps*
        :do (unless (lem:forward-sexp 1 t) (return))
            (when (zerop (mod i *bench-t2-lisp-edit-sexp-render-every*))
              (lem:window-see (lem:current-window))
              (bench-t2-render)))
  (loop :for i :from 1 :to *bench-t2-lisp-edit-sexp-steps*
        :do (unless (lem:backward-sexp 1 t) (return))
            (when (zerop (mod i *bench-t2-lisp-edit-sexp-render-every*))
              (lem:window-see (lem:current-window))
              (bench-t2-render))))

(defun bench-t2-lisp-edit-rescan (point)
  "Re-syntax-scan the region a few lines around POINT (the after-edit re-scan)."
  (lem:with-point ((start point) (end point))
    (lem:line-offset start (- *bench-t2-lisp-edit-rescan-lines*))
    (lem:line-offset end *bench-t2-lisp-edit-rescan-lines*)
    (lem:syntax-scan-region start end)))

(defun bench-t2-lisp-edit-indent-pass (point)
  "Indent-heavy editing: at deterministic nesting points, `newline-and-indent',
re-scan the touched region, and render."
  (dotimes (k *bench-t2-lisp-edit-indent-edits*)
    (let ((line (1+ (* (1+ k) 9))))            ; lines 10, 19, 28, ...
      (lem:move-to-line point line)
      (lem:line-end point)                     ; a nesting point: end of a form line
      (lem/language-mode:newline-and-indent 1)
      (bench-t2-lisp-edit-rescan point)
      (lem:window-see (lem:current-window))
      (bench-t2-render))))

(defun bench-t2-lisp-edit-run (buffer)
  (lem:switch-to-buffer buffer)
  (let ((point (lem:buffer-point buffer)))
    (lem:move-to-beginning-of-buffer)
    (bench-t2-render)
    (bench-t2-lisp-edit-sexp-sweep)
    (bench-t2-lisp-edit-indent-pass point)
    ;; Undo the indent edits, restoring the corpus base (the corpus insert was
    ;; undo-disabled, so the drain stops at the base text).
    (loop :while (lem:buffer-undo point))
    (lem:move-to-beginning-of-buffer)
    (bench-t2-render)))

(register-t2-workload
 :name "lisp-edit"
 :setup #'bench-t2-lisp-edit-setup
 :run #'bench-t2-lisp-edit-run)
