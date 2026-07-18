;;;; syntax.lisp -- T1 entry: tmlanguage syntax scan (SPEC-PERF PF-4).
;;;;
;;;; `lem:syntax-scan-region' (src/buffer/internal/tmlanguage.lisp) run over the
;;;; committed `lisp-500k' corpus in a buffer carrying the REAL lisp-mode
;;;; grammar.  The grammar is `lem-lisp-mode/grammar:make-tmlanguage-lisp'
;;;; (extensions/lisp-mode/grammar.lisp): dozens of ppcre-backed match/region
;;;; patterns (defun/defclass/keyword/string/comment/feature-expression ...),
;;;; the exact tmlanguage the editor applies to Common Lisp.  That file depends
;;;; only on `lem/core' + cl-ppcre (both already in the bench image), so it is
;;;; loaded directly rather than pulling the whole `lem-lisp-mode' system (which
;;;; drags in usocket/micros/lsp) -- the same headless-scan setup the
;;;; tests/long-line-scan.lisp tests use, but against the real grammar instead
;;;; of a synthetic one.
;;;;
;;;; `syntax-scan-region' unconditionally re-scans start..end (the scanned-region
;;;; cache lives in `syntax-scan-window', not here), and re-scanning is
;;;; idempotent in cost, so the corpus buffer is built once at load time and each
;;;; section re-scans it; a single full scan (~0.1 s) already dwarfs the 10 ms
;;;; window, so INNER is 1.
;;;;
;;;; NOTE: the corpus lines are ordinary source lines, all under the
;;;; `long-line-scan-threshold' (10 000), so none are skipped by the long-line
;;;; cap -- the whole corpus is scanned.

(in-package :cl-user)

;;;; ------------------------------------------------------------------
;;;; Real lisp-mode grammar (loaded from the committed extension file)
;;;; ------------------------------------------------------------------

(defun bench-load-lisp-grammar ()
  "Load extensions/lisp-mode/grammar.lisp and return `make-tmlanguage-lisp'.
The repo root is derived from this driver's directory (scripts/bench/ -> root)."
  (let* ((root (uiop:pathname-parent-directory-pathname
                (uiop:pathname-parent-directory-pathname *bench-source-dir*)))
         (grammar (merge-pathnames "extensions/lisp-mode/grammar.lisp" root)))
    (load grammar)
    (or (find-symbol "MAKE-TMLANGUAGE-LISP" :lem-lisp-mode/grammar)
        (error "grammar.lisp did not define make-tmlanguage-lisp"))))

(defparameter *bench-syntax-buffer*
  (let* ((make-tmlanguage-lisp (bench-load-lisp-grammar))
         (table (lem:make-syntax-table))
         (buffer (progn
                   (lem:set-syntax-parser table (funcall make-tmlanguage-lisp))
                   (lem:make-buffer "bench-syntax" :temporary t
                                                   :enable-undo-p nil
                                                   :syntax-table table))))
    ;; Insert BEFORE enabling highlight so the insertion itself triggers no scan
    ;; (matching tests/long-line-scan.lisp); the timed op scans explicitly.
    (lem:insert-string (lem:buffer-point buffer)
                       (uiop:read-file-string (bench-ensure-corpus :lisp-500k)))
    (setf (lem:variable-value 'lem:enable-syntax-highlight :buffer buffer) t)
    buffer)
  "The lisp-500k corpus in a buffer carrying the real lisp-mode tmlanguage.")

;;;; ------------------------------------------------------------------
;;;; Op / registration
;;;; ------------------------------------------------------------------

(defun bench-syntax-op (buffer count)
  "Full-buffer `syntax-scan-region' COUNT times (idempotent per scan)."
  (dotimes (i count)
    (lem:syntax-scan-region (lem:buffer-start-point buffer)
                            (lem:buffer-end-point buffer))))

(register-bench-entry
 :name "syntax/lisp-500k"
 :unit "us/op"
 :inner 1                              ; one 500 KB scan ~0.1 s >> 10 ms window
 :setup (lambda () *bench-syntax-buffer*)
 :op #'bench-syntax-op)
