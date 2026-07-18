;;;; width.lisp -- T1 entry: string-width (SPEC-PERF PF-4).
;;;;
;;;; `lem:string-width' is the kernel-backed, redisplay-hot width primitive
;;;; (src/common/character/string-width-utils.lisp -> the ACL2-certified
;;;; `lem/kernel:k-char-width' via verified/width.lisp).  Every rendered row
;;;; folds it over the line's codepoints, so its per-codepoint cost is on the
;;;; critical path of every redisplay.  This entry measures that fold over four
;;;; width classes, each stressing a different branch of the kernel's cond:
;;;;
;;;;   width/ascii  -- narrow Latin (the fast common case)
;;;;   width/cjk    -- East-Asian wide (the eastasian range-table branch)
;;;;   width/emoji  -- wide pictographs, some outside the BMP
;;;;   width/mixed  -- the committed unicode-mixed corpus (ASCII + CJK + emoji +
;;;;                   combining marks: exercises zero-width and every branch in
;;;;                   one realistic string)
;;;;
;;;; The ascii/cjk/emoji strings are fixed-content (a deterministic cycle over a
;;;; fixed codepoint pool -- no RNG), so `string-width' is a pure function of a
;;;; constant input and every repetition is byte-identical.  The op accumulates
;;;; the returned widths so the call cannot be elided as dead code.

(in-package :cl-user)

;;;; ------------------------------------------------------------------
;;;; Fixed-content width strings (deterministic by construction)
;;;; ------------------------------------------------------------------

(defparameter *bench-width-length* 4000
  "Character length of the ascii/cjk/emoji width strings.  A 4000-codepoint
fold costs ~0.1 ms/op, so a few hundred iterations clear the >= 10 ms window.")

(defparameter *bench-width-ascii-pool*
  (coerce (loop :for c :from 32 :to 126 :collect c) 'vector)
  "Printable ASCII (all narrow).")

(defparameter *bench-width-cjk-pool*
  (coerce (loop :for c :from #x4E00 :to #x4E7F :collect c) 'vector)
  "A block of common CJK unified ideographs (all wide).")

(defparameter *bench-width-emoji-pool*
  #(#x1F600 #x1F601 #x1F602 #x1F609 #x1F60A #x1F60D #x1F914 #x1F44D
    #x1F525 #x1F389 #x1F680 #x2764 #x2728 #x1F4A9 #x1F92F #x1F971)
  "Emoji / pictographic codepoints (wide; several outside the BMP).")

(defun bench-width-cycle-string (pool length)
  "A LENGTH-character string cycling deterministically through POOL."
  (let ((s (make-string length))
        (n (length pool)))
    (dotimes (i length s)
      (setf (char s i) (code-char (aref pool (mod i n)))))))

(defparameter *bench-width-strings*
  (list :ascii (bench-width-cycle-string *bench-width-ascii-pool* *bench-width-length*)
        :cjk   (bench-width-cycle-string *bench-width-cjk-pool* *bench-width-length*)
        :emoji (bench-width-cycle-string *bench-width-emoji-pool* *bench-width-length*)
        :mixed (uiop:read-file-string (bench-ensure-corpus :unicode-mixed)))
  "The four immutable width-class strings, built once at load time.")

;;;; ------------------------------------------------------------------
;;;; Op (pure; accumulates so the width call is not dead code)
;;;; ------------------------------------------------------------------

(defun bench-width-op (string count)
  "Fold `lem:string-width' over STRING COUNT times, accumulating the result so
the call is not elided."
  (let ((acc 0))
    (declare (type fixnum acc))
    (dotimes (i count acc)
      (setf acc (logand (+ acc (the fixnum (lem:string-width string)))
                        most-positive-fixnum)))))

;;;; ------------------------------------------------------------------
;;;; Registration (window >= 10 ms; per-op cost is iteration-independent)
;;;; ------------------------------------------------------------------

(defparameter *bench-width-inner*
  '((:ascii . 180) (:cjk . 180) (:emoji . 180) (:mixed . 12))
  "Iteration counts: the 4000-char classes ~0.1 ms/op, the ~49 KB mixed corpus
~1.4 ms/op.")

(dolist (spec *bench-width-inner*)
  (destructuring-bind (class . inner) spec
    (let ((string (getf *bench-width-strings* class)))
      (register-bench-entry
       :name (format nil "width/~(~A~)" class)
       :unit "us/op"
       :inner inner
       :setup (lambda () string)
       :op #'bench-width-op))))
