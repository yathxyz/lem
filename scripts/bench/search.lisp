;;;; search.lisp -- T1 entry: buffer search (SPEC-PERF PF-4).
;;;;
;;;; The four frozen public search primitives (src/buffer/internal/search.lisp):
;;;;   search/forward-literal   -- `lem:search-forward'
;;;;   search/backward-literal  -- `lem:search-backward'
;;;;   search/forward-regexp    -- `lem:search-forward-regexp'
;;;;   search/backward-regexp   -- `lem:search-backward-regexp'
;;;; each sweeping the whole `lisp-500k' corpus buffer (~13 000 lines) for an
;;;; ABSENT needle.  An absent needle is the deterministic worst case: the search
;;;; visits every line (literal: a case-folding `search' per line; regexp: a
;;;; `ppcre:scan' per line) and, on failure, `search-step' restores the point to
;;;; its origin -- so the op is net-zero and the buffer/point state is invariant
;;;; across repetitions.  A found needle would stop early at a
;;;; corpus-content-dependent line, making the number fragile to corpus edits;
;;;; the full sweep is stable and measures the per-line scan cost that dominates
;;;; a real miss (and the tail of a real hit).
;;;;
;;;; The corpus buffer is built once at load time and never mutated (search is
;;;; read-only), so every section shares it; each section's `:setup' hands the op
;;;; a fresh temporary point at the sweep origin (buffer start for forward,
;;;; buffer end for backward).

(in-package :cl-user)

(defparameter *bench-search-buffer*
  (let ((buffer (lem:make-buffer "bench-search" :temporary t :enable-undo-p nil)))
    (lem:insert-string (lem:buffer-point buffer)
                       (uiop:read-file-string (bench-ensure-corpus :lisp-500k)))
    buffer)
  "The immutable large-buffer corpus every search section sweeps.")

(defparameter *bench-search-literal-needle* "zzqqxx-no-such-token"
  "A literal needle guaranteed absent from Lisp source (forces a full sweep).")

(defparameter *bench-search-regexp-needle* "zzqq[0-9]xx-no-such-token"
  "A regexp whose fixed prefix is absent, so `ppcre:scan' rejects every line.")

;;;; ------------------------------------------------------------------
;;;; Ops (net-zero: an absent needle leaves the point at its origin)
;;;; ------------------------------------------------------------------

(defun bench-search-op (search-fn needle)
  "An op running the frozen SEARCH-FN for the absent NEEDLE COUNT times."
  (lambda (point count)
    (dotimes (i count)
      (funcall search-fn point needle))))

(defun bench-search-forward-setup ()
  (lem:copy-point (lem:buffer-start-point *bench-search-buffer*) :temporary))

(defun bench-search-backward-setup ()
  (lem:copy-point (lem:buffer-end-point *bench-search-buffer*) :temporary))

;;;; ------------------------------------------------------------------
;;;; Registration (window >= 10 ms; a full 500 KB sweep is ~7-14 ms/op)
;;;; ------------------------------------------------------------------
;;;;
;;;; INNER is folded into the op closure (a full sweep already exceeds the 10 ms
;;;; window, so the driver INNER is 1 and the op does its own COUNT sweeps).

(dolist (spec (list (list "search/forward-literal"  #'lem:search-forward
                          *bench-search-literal-needle* #'bench-search-forward-setup 2)
                    (list "search/backward-literal" #'lem:search-backward
                          *bench-search-literal-needle* #'bench-search-backward-setup 2)
                    (list "search/forward-regexp"   #'lem:search-forward-regexp
                          *bench-search-regexp-needle* #'bench-search-forward-setup 3)
                    (list "search/backward-regexp"  #'lem:search-backward-regexp
                          *bench-search-regexp-needle* #'bench-search-backward-setup 3)))
  (destructuring-bind (name search-fn needle setup sweeps) spec
    (register-bench-entry
     :name name
     :unit "us/op"
     :inner sweeps
     :setup setup
     :op (bench-search-op search-fn needle))))
