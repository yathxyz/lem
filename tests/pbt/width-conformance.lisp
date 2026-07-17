;;;; tests/pbt/width-conformance.lisp -- SPEC-VK VK-10 differential + property acceptance.
;;;;
;;;; Pins the certified width kernel (verified/width.lisp + verified/eastasian-data.lisp,
;;;; loaded through verified/shim.lisp) two ways:
;;;;
;;;;   1. FIXED REGRESSION VECTORS (tests/pbt/width-vectors.lisp) -- ~228 width +
;;;;      ~213 wide-index (codepoints, tab-size, ambiguous-width, expected)
;;;;      triples captured from the ORIGINAL production char-width/string-width/
;;;;      wide-index BEFORE the one-source swap.  A post-swap differential against
;;;;      live production is vacuous (production now delegates to the kernel), so
;;;;      the frozen vectors ARE the independent oracle.  Two checks per vector:
;;;;        (a) the KERNEL reproduces the frozen number (kernel == old production);
;;;;        (b) the kernel-backed PRODUCTION reproduces it too (swap changed
;;;;            nothing observable -- the "tests must pass unchanged" guarantee).
;;;;
;;;;   2. PROPERTY TESTS of the four certified theorems, evaluated on random
;;;;      inputs through the executable kernel (the proofs hold of the logic; these
;;;;      confirm the shim-loaded exec code satisfies them on generated data):
;;;;      additivity/fold, prefix monotonicity, the tab-stop law, and the
;;;;      wide-index Galois/least-index property.
;;;;
;;;; Codepoint<->string conversion (code-char / char-code) happens here, never
;;;; inside a book.

(defpackage :lem-tests/pbt/width-conformance
  (:use :cl
        :rove
        :lem-tests/pbt/harness)
  (:import-from :lem
                :string-width
                :wide-index
                :*ambiguous-character-width*)
  (:import-from :lem-tests/pbt/width-vectors
                :*width-vectors*
                :*wide-index-vectors*))
(in-package :lem-tests/pbt/width-conformance)

;;; ------------------------------------------------------------------
;;; Kernel loading + accessors (find-symbol: no read-time package dep)
;;; ------------------------------------------------------------------

(defun repo-root ()
  (asdf:system-source-directory :lem-tests))

(defun ensure-kernel-loaded ()
  "Load the shim + certified width book into this image once (idempotent)."
  (handler-bind ((warning #'muffle-warning))
    (unless (find-package "LEM/KERNEL")
      (load (merge-pathnames "verified/shim.lisp" (repo-root))))
    (let ((k (find-symbol "K-CHAR-WIDTH" "LEM/KERNEL")))
      (when (or (null k) (not (fboundp k)))
        (funcall (find-symbol "LOAD-VERIFIED-BOOK" "LEM/KERNEL") "width")))))

(defun kcw (code col tab-size icon-p amb)
  (funcall (find-symbol "K-CHAR-WIDTH" "LEM/KERNEL") code col tab-size icon-p amb))
(defun ksw (codes col tab-size amb)
  (funcall (find-symbol "K-STRING-WIDTH" "LEM/KERNEL") codes col tab-size amb))
(defun kwi (codes goal col tab-size amb)
  (funcall (find-symbol "K-WIDE-INDEX" "LEM/KERNEL") codes goal col tab-size amb))

(defun cps->string (codepoints)
  (map 'string #'code-char codepoints))

(defun cl-take (n list)
  (loop :repeat n :for x :in list :collect x))

;;; ------------------------------------------------------------------
;;; 1. Fixed regression vectors (kernel AND production vs frozen oracle)
;;; ------------------------------------------------------------------

(deftest width-vectors-kernel
  (ensure-kernel-loaded)
  (let ((mismatches 0))
    (dolist (v *width-vectors*)
      (destructuring-bind (cps tab-size amb expected) v
        (unless (eql (ksw cps 0 tab-size amb) expected)
          (incf mismatches))))
    (ok (zerop mismatches)
        (format nil "kernel k-string-width matches all ~D frozen width vectors (~D off)"
                (length *width-vectors*) mismatches)))
  (let ((mismatches 0))
    (dolist (v *wide-index-vectors*)
      (destructuring-bind (cps goal tab-size amb expected) v
        (unless (eql (kwi cps goal 0 tab-size amb) expected)
          (incf mismatches))))
    (ok (zerop mismatches)
        (format nil "kernel k-wide-index matches all ~D frozen wide-index vectors (~D off)"
                (length *wide-index-vectors*) mismatches))))

(deftest width-vectors-production
  ;; The kernel-backed production shell must still reproduce the pre-swap numbers.
  (let ((mismatches 0))
    (dolist (v *width-vectors*)
      (destructuring-bind (cps tab-size amb expected) v
        (let ((*ambiguous-character-width* amb))
          (unless (eql (string-width (cps->string cps) :tab-size tab-size) expected)
            (incf mismatches)))))
    (ok (zerop mismatches)
        (format nil "production string-width unchanged by the swap on all ~D width vectors (~D off)"
                (length *width-vectors*) mismatches)))
  (let ((mismatches 0))
    (dolist (v *wide-index-vectors*)
      (destructuring-bind (cps goal tab-size amb expected) v
        (let ((*ambiguous-character-width* amb))
          (unless (eql (wide-index (cps->string cps) goal :tab-size tab-size) expected)
            (incf mismatches)))))
    (ok (zerop mismatches)
        (format nil "production wide-index unchanged by the swap on all ~D wide-index vectors (~D off)"
                (length *wide-index-vectors*) mismatches))))

;;; ------------------------------------------------------------------
;;; 2. Property tests of the certified theorems (random inputs)
;;; ------------------------------------------------------------------

;; Interesting codepoints spanning every classification branch (no bare 10 here;
;; newline is injected explicitly only where a property tolerates it).
(defparameter *pool*
  (coerce (append (loop :for c :from 32 :to 126 :collect c)   ; printable ASCII
                  (list 9 9)                                   ; tab
                  (loop :for c :from 0 :to 8 :collect c)       ; control
                  (list 13 27 127 #xE000 #xE063 #xE0FF)        ; control / \N
                  (list #x3042 #x4E2D #xAC00 #x1100 #xFF01)    ; wide
                  (list #x1F600 #x1FAE0 #x1F468)               ; emoji
                  (list #x301 #xFE0F #x200D)                   ; zero-width
                  (list #xA7 #x2460 #x25BC))                   ; ambiguous / ▼
          'vector))

(defun gen-nonnl-codes (&key (max-len 20))
  "Random newline-free codepoint list."
  (make-generator
   :sample (lambda (rng)
             (loop :repeat (rng-below rng (1+ max-len))
                   :collect (rng-element rng *pool*)))
   :shrink (constantly nil)))

(defun gen-tab-size (rng) (nth (rng-below rng 4) '(1 2 4 8)))
(defun gen-amb (rng) (nth (rng-below rng 2) '(1 2)))

(deftest additivity-fold-law
  ;; k-string-width(a ++ b, c) = k-string-width(b, k-string-width(a, c))
  (ensure-kernel-loaded)
  (for-all ((a (gen-nonnl-codes))
            (b (gen-nonnl-codes))
            (seed (gen-integer :min 0 :max 1000000)))
    (let* ((rng (make-rng seed))
           (ts (gen-tab-size rng))
           (amb (gen-amb rng))
           (c (rng-below rng 20)))
      (= (ksw (append a b) c ts amb)
         (ksw b (ksw a c ts amb) ts amb)))))

(deftest prefix-monotonicity
  ;; newline-free: width of a prefix <= width of the whole
  (ensure-kernel-loaded)
  (for-all ((codes (gen-nonnl-codes))
            (seed (gen-integer :min 0 :max 1000000)))
    (let* ((rng (make-rng seed))
           (ts (gen-tab-size rng))
           (amb (gen-amb rng))
           (n (rng-below rng (1+ (length codes)))))
      (<= (ksw (cl-take n codes) 0 ts amb)
          (ksw codes 0 ts amb)))))

(deftest tab-stop-law
  ;; after a tab: least multiple of tab-size strictly greater than the column
  (ensure-kernel-loaded)
  (for-all ((seed (gen-integer :min 0 :max 100000000)))
    (let* ((rng (make-rng seed))
           (col (rng-below rng 64))
           (ts (nth (rng-below rng 4) '(1 2 4 8)))
           (w (kcw 9 col ts nil 1)))
      (and (> w col)                       ; strictly greater
           (zerop (mod w ts))              ; a multiple
           (<= (- w ts) col)))))           ; the LEAST such multiple

(deftest wide-index-galois
  ;; If wide-index returns i: width(take i) <= goal < width(take i+1).
  ;; It returns NIL exactly when goal >= total width (whole run fits).
  (ensure-kernel-loaded)
  (for-all ((codes (gen-nonnl-codes))
            (seed (gen-integer :min 0 :max 100000000)))
    (let* ((rng (make-rng seed))
           (ts (gen-tab-size rng))
           (amb (gen-amb rng))
           (total (ksw codes 0 ts amb))
           (goal (rng-below rng (+ 2 total)))
           (i (kwi codes goal 0 ts amb)))
      (if i
          (and (<= (ksw (cl-take i codes) 0 ts amb) goal)
               (< goal (ksw (cl-take (1+ i) codes) 0 ts amb))
               (< goal total))             ; non-nil <=> goal exceeded
          (>= goal total)))))              ; nil <=> whole run fits
