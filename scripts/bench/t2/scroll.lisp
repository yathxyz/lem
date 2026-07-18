;;;; scroll.lisp -- T2 workload: sustained scroll over styled text (PF-5).
;;;;
;;;; A syntax-highlighted Common Lisp buffer built from the PINNED `lisp-500k'
;;;; corpus (~13 000 lines), carrying the REAL lisp-mode tmlanguage grammar
;;;; (extensions/lisp-mode/grammar.lisp -- the same headless-grammar setup the
;;;; T1 `syntax' entry uses, loaded directly to avoid lem-lisp-mode's heavy
;;;; transitive deps).  The whole buffer is syntax-scanned once at setup so the
;;;; rendered rows carry real syntax attributes (styled text).  RUN then does a
;;;; SUSTAINED line-scroll pass (`scroll-down' one line at a time) followed by a
;;;; page-scroll pass (`next-page'), forcing a full redisplay per step -- the
;;;; scroll-throughput-over-styled-text session (SPEC-PERF PF-5 scroll row).
;;;;
;;;; Bounded passes: the corpus is ~13 000 lines; scrolling every line one at a
;;;; time end to end would be ~13 000 forced frames.  A fixed sustained window
;;;; (1500 line-scrolls + 150 page-scrolls) is a representative, gate-stable
;;;; sustained pass without an unbounded runtime.  `scroll-down'/`next-page'
;;;; signal `lem:end-of-buffer' at the bottom (caught -> pass ends early if the
;;;; corpus is ever shorter than the pass).
;;;;
;;;; Replayability: read-only scrolling; RUN resets to buffer start at entry, so
;;;; every execution renders the identical frame sequence.

(in-package :cl-user)

(defparameter *bench-t2-scroll-line-steps* 1500)
(defparameter *bench-t2-scroll-page-steps* 150)

(defun bench-t2-load-lisp-grammar ()
  "Load the real lisp-mode tmlanguage and return `make-tmlanguage-lisp'."
  (let ((grammar (merge-pathnames "extensions/lisp-mode/grammar.lisp" (bench-repo-root))))
    (load grammar)
    (or (find-symbol "MAKE-TMLANGUAGE-LISP" :lem-lisp-mode/grammar)
        (error "grammar.lisp did not define make-tmlanguage-lisp"))))

(defun bench-t2-scroll-setup ()
  "Build the styled lisp-500k buffer once (grammar + full syntax scan)."
  (let* ((make-tmlanguage-lisp (bench-t2-load-lisp-grammar))
         (table (lem:make-syntax-table))
         (buffer (progn
                   (lem:set-syntax-parser table (funcall make-tmlanguage-lisp))
                   (lem:make-buffer "bench-t2-scroll" :temporary t
                                                      :enable-undo-p nil
                                                      :syntax-table table))))
    (lem:insert-string (lem:buffer-point buffer)
                       (uiop:read-file-string (bench-ensure-corpus :lisp-500k)))
    (setf (lem:variable-value 'lem:enable-syntax-highlight :buffer buffer) t)
    (lem:syntax-scan-region (lem:buffer-start-point buffer)
                            (lem:buffer-end-point buffer))
    buffer))

(defun bench-t2-scroll-run (buffer)
  (lem:switch-to-buffer buffer)
  ;; Sustained line-scroll pass.
  (lem:move-to-beginning-of-buffer)
  (bench-t2-render)
  (handler-case
      (dotimes (i *bench-t2-scroll-line-steps*)
        (lem:scroll-down 1)
        (bench-t2-render))
    (lem:end-of-buffer () nil))
  ;; Page-scroll pass.
  (lem:move-to-beginning-of-buffer)
  (bench-t2-render)
  (handler-case
      (dotimes (i *bench-t2-scroll-page-steps*)
        (lem:next-page)
        (bench-t2-render))
    (lem:end-of-buffer () nil)))

(register-t2-workload
 :name "scroll"
 :setup #'bench-t2-scroll-setup
 :run #'bench-t2-scroll-run)
