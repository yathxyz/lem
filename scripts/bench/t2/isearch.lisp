;;;; isearch.lisp -- T2 workload: incremental search over the 10 MB file (PF-5).
;;;;
;;;; Incremental-search session over the committed `mixed-10m' corpus (~10 MB,
;;;; ~244 000 lines) with three needles (SPEC-PERF PF-5 isearch row):
;;;;   common  "the"              -- ~34 700 hits (dense; step a bounded window)
;;;;   rare    "attribute cache"  -- ~213 hits (sparse; long scans between hits)
;;;;   absent  "zqxj-absent-vvv"  -- 0 hits (one full-buffer scan, no match)
;;;; The hit counts are a deterministic property of the pinned corpus generator.
;;;;
;;;; -------------------------------------------------------------------------
;;;; HEADLESS-ISEARCH DEVIATION (documented -- see bench/README.md).  The
;;;; interactive isearch command loop (`lem/isearch:isearch-forward' ->
;;;; `isearch-start' installs a minor mode and then `read-key's each keystroke,
;;;; with a floating popup message) CANNOT run headlessly without a real input
;;;; loop feeding key events.  Per the P2 task's stated fallback, this workload
;;;; drives the search machinery at per-keystroke granularity instead, and it
;;;; drives the REAL isearch engine, not a reimplementation:
;;;;   * incremental typing -- for each prefix of the needle it calls the real
;;;;     `lem/isearch::isearch-update-buffer' (the exact function
;;;;     `isearch-update-display' calls to search the visible window region and
;;;;     build the match-highlight overlays), then forces a redisplay.  This is
;;;;     the per-keystroke highlight cost the interactive loop incurs.
;;;;   * match stepping -- the `isearch-next' path is the frozen public
;;;;     `lem:search-forward' advancing the cursor match by match; each step
;;;;     scrolls the view (`window-see') and re-highlights, forcing a redisplay.
;;;; What is NOT driven: the minor-mode entry, `read-key', and the popup message
;;;; (all input-loop / frontend-interactive, not search work).
;;;; -------------------------------------------------------------------------
;;;;
;;;; Replayability: read-only (search + transient highlight overlays, which RUN
;;;; resets after each needle and at entry); RUN resets the cursor to buffer
;;;; start, so every execution renders the identical frame sequence.

(in-package :cl-user)

(defparameter *bench-t2-isearch-common-needle* "the"
  "Dense needle (~34 700 hits in mixed-10m); match stepping is capped.")
(defparameter *bench-t2-isearch-rare-needle* "attribute cache"
  "Sparse needle (~213 hits): long scans between hits, stepped to exhaustion.")
(defparameter *bench-t2-isearch-absent-needle* "zqxj-absent-vvv"
  "Needle guaranteed absent from the corpus: one full-buffer scan, no match.")

(defparameter *bench-t2-isearch-common-step-cap* 250
  "Match-stepping cap for the dense needle (its hits are effectively unbounded
over 10 MB, so the stepped window is fixed for a gate-stable, bounded session).")

(defparameter *bench-t2-isearch-sparse-step-cap* 1000
  "Match-stepping cap for the sparse/absent needles: high enough that both
exhaust naturally (rare ~213, absent 0) -- the cap is only a safety bound.")

;;;; The real isearch highlight function and its two search-function specials
;;;; live in the (locked) :lem/isearch package; resolve them once by name.
(defparameter *bench-t2-isearch-update*
  (or (find-symbol "ISEARCH-UPDATE-BUFFER" :lem/isearch)
      (error "lem/isearch::isearch-update-buffer not found"))
  "The real `isearch-update-buffer' (visible-region search + highlight overlays).")

(defparameter *bench-t2-isearch-reset*
  (or (find-symbol "ISEARCH-RESET-OVERLAYS" :lem/isearch)
      (error "lem/isearch::isearch-reset-overlays not found"))
  "The real overlay-clearing routine, so highlights do not leak across needles.")

(defparameter *bench-t2-isearch-fwd-fn*
  (or (find-symbol "*ISEARCH-SEARCH-FORWARD-FUNCTION*" :lem/isearch)
      (error "isearch forward-function special not found")))
(defparameter *bench-t2-isearch-bwd-fn*
  (or (find-symbol "*ISEARCH-SEARCH-BACKWARD-FUNCTION*" :lem/isearch)
      (error "isearch backward-function special not found")))

(defun bench-t2-isearch-setup ()
  "Build a private 10 MB buffer (its own copy, NOT the shared find-file-buffer,
so it cannot collide with the big-file workload's buffer)."
  (let ((buffer (lem:make-buffer "bench-t2-isearch" :temporary t :enable-undo-p nil)))
    (lem:insert-string (lem:buffer-point buffer)
                       (uiop:read-file-string (bench-ensure-corpus :mixed-10m)))
    buffer))

(defun bench-t2-isearch-highlight (point needle)
  "Call the real isearch visible-region search + highlight for NEEDLE, with the
isearch search-function specials bound to the frozen literal search functions."
  (progv (list *bench-t2-isearch-fwd-fn* *bench-t2-isearch-bwd-fn*)
      (list #'lem:search-forward #'lem:search-backward)
    (funcall *bench-t2-isearch-update* point needle)))

(defun bench-t2-isearch-one-needle (buffer needle step-cap)
  "One incremental-search session for NEEDLE: type it prefix by prefix
(re-highlighting the visible region per keystroke), then step through up to
STEP-CAP matches (scrolling + re-highlighting + rendering per step)."
  (let ((point (lem:buffer-point buffer)))
    ;; Incremental typing: one keystroke at a time, real highlight per prefix.
    (lem:move-to-beginning-of-buffer)
    (loop :for k :from 1 :to (length needle)
          :for prefix := (subseq needle 0 k)
          :do (bench-t2-isearch-highlight point prefix)
              (bench-t2-render))
    ;; Match stepping (the isearch-next path): search-forward advances the
    ;; cursor to each successive match; scroll it into view and re-highlight.
    (lem:move-to-beginning-of-buffer)
    (loop :repeat step-cap
          :while (lem:search-forward point needle)
          :do (lem:window-see (lem:current-window))
              (bench-t2-isearch-highlight point needle)
              (bench-t2-render))
    (funcall *bench-t2-isearch-reset* buffer)))

(defun bench-t2-isearch-run (buffer)
  (lem:switch-to-buffer buffer)
  (funcall *bench-t2-isearch-reset* buffer)
  (bench-t2-isearch-one-needle buffer *bench-t2-isearch-common-needle*
                               *bench-t2-isearch-common-step-cap*)
  (bench-t2-isearch-one-needle buffer *bench-t2-isearch-rare-needle*
                               *bench-t2-isearch-sparse-step-cap*)
  (bench-t2-isearch-one-needle buffer *bench-t2-isearch-absent-needle*
                               *bench-t2-isearch-sparse-step-cap*)
  ;; Leave the cursor at buffer start so the next execution replays identically.
  (lem:move-to-beginning-of-buffer))

(register-t2-workload
 :name "isearch"
 :setup #'bench-t2-isearch-setup
 :run #'bench-t2-isearch-run)
