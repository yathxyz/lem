;;;; generate.lisp -- deterministic bench corpus generators (SPEC-PERF PF-4).
;;;;
;;;; Corpora are NOT committed as blobs; this generator is.  It produces every
;;;; corpus deterministically (fixed SplitMix64 seed, fixed inputs) into a
;;;; gitignored cache directory at bench time, so a fresh checkout regenerates
;;;; byte-identical files.  The bench driver loads this file and calls
;;;; `bench-ensure-corpus' / `bench-ensure-all-corpora'.
;;;;
;;;; Corpora (SPEC-PERF PF-4 "fixed corpora committed under bench/corpora/"):
;;;;   :lisp-500k      ~500 KB syntactically-valid Common Lisp -- a deterministic
;;;;                   concatenation of whole real repo source files (whole files
;;;;                   only, so the result is valid by construction).
;;;;   :unicode-mixed  ~100 KB of mixed ASCII / CJK / emoji / combining-mark text
;;;;                   (the kernel string-width path's corpus).
;;;;   :long-line-200k  a single 200 000-char line, no newline (the PI-1 corpus
;;;;                   the edit/points benchmarks stress).
;;;;
;;;; SplitMix64 is reproduced locally rather than reused from
;;;; tests/pbt/harness.lisp: that harness lives in the `lem-tests' load graph
;;;; (rove et al.), which the bench image (`:lem/core' only) does not pull in.
;;;; A ~15-line PRNG keeps the bench scripts self-contained.

(in-package :cl-user)

;;;; ------------------------------------------------------------------
;;;; SplitMix64 (deterministic; identical algorithm to the PBT harness)
;;;; ------------------------------------------------------------------

(defconstant +bench-u64-mask+ #xFFFFFFFFFFFFFFFF)

(defstruct (bench-rng (:constructor bench-make-rng (seed &aux (state (logand seed +bench-u64-mask+)))))
  (state 0 :type (unsigned-byte 64)))

(defun bench-next-u64 (rng)
  "Advance RNG and return the next 64-bit unsigned value (SplitMix64)."
  (let ((z (setf (bench-rng-state rng)
                 (logand (+ (bench-rng-state rng) #x9E3779B97F4A7C15) +bench-u64-mask+))))
    (setf z (logand (* (logxor z (ash z -30)) #xBF58476D1CE4E5B9) +bench-u64-mask+))
    (setf z (logand (* (logxor z (ash z -27)) #x94D049BB133111EB) +bench-u64-mask+))
    (logand (logxor z (ash z -31)) +bench-u64-mask+)))

(defun bench-rng-below (rng n)
  "Uniformly random integer in [0, N)."
  (if (<= n 1) 0 (mod (bench-next-u64 rng) n)))

(defun bench-rng-element (rng vector)
  (aref vector (bench-rng-below rng (length vector))))

;;;; ------------------------------------------------------------------
;;;; Locations
;;;; ------------------------------------------------------------------

(defparameter *bench-corpora-dir*
  (uiop:pathname-directory-pathname (or *load-truename* *default-pathname-defaults*))
  "Directory holding this generator (bench/corpora/).")

(defun bench-repo-root ()
  "The repository root (bench/corpora/ -> bench/ -> root)."
  (uiop:pathname-parent-directory-pathname
   (uiop:pathname-parent-directory-pathname *bench-corpora-dir*)))

(defun bench-corpus-cache-dir ()
  "The gitignored cache directory the corpora are generated into.  Override
with LEM_BENCH_CORPUS_DIR."
  (let ((override (uiop:getenv "LEM_BENCH_CORPUS_DIR")))
    (uiop:ensure-directory-pathname
     (if (and override (plusp (length override)))
         override
         (merge-pathnames "cache/" *bench-corpora-dir*)))))

(defparameter *bench-corpus-files*
  '(("lisp-500k"      . "lisp-500k.lisp")
    ("unicode-mixed"  . "unicode-mixed.txt")
    ("long-line-200k" . "long-line-200k.txt"))
  "Corpus name -> cache filename.")

(defun bench-corpus-name-string (name)
  (etypecase name
    (string name)
    (symbol (string-downcase (symbol-name name)))))

(defun bench-corpus-path (name)
  "Cache pathname for corpus NAME (a keyword or string), without generating."
  (let* ((key (bench-corpus-name-string name))
         (file (cdr (assoc key *bench-corpus-files* :test #'string=))))
    (unless file
      (error "unknown bench corpus: ~A" name))
    (merge-pathnames file (bench-corpus-cache-dir))))

;;;; ------------------------------------------------------------------
;;;; Corpus content builders (deterministic)
;;;; ------------------------------------------------------------------

(defparameter *bench-lisp-source-files*
  '("src/metrics.lisp"
    "src/buffer/internal/buffer-insert.lisp"
    "src/buffer/internal/point.lisp"
    "src/buffer/internal/basic.lisp"
    "src/buffer/internal/undo.lisp"
    "src/buffer/internal/buffer.lisp")
  "Committed repo files concatenated (whole, so the result parses) to build the
Lisp corpus.  Fixed list -> deterministic bytes.")

(defparameter +bench-lisp-target-bytes+ (* 500 1024))
(defparameter +bench-unicode-target-bytes+ (* 100 1024))
(defparameter +bench-long-line-length+ 200000)

(defun bench-build-lisp-500k ()
  "Concatenate whole repo source files in a deterministic (seeded) order,
repeating the shuffled list until the byte target is reached.  Appending only
whole files keeps the corpus syntactically valid by construction."
  (let* ((root (bench-repo-root))
         (rng (bench-make-rng #xB1A5E115F0000001))   ; distinct fixed seed per corpus
         (sources (loop :for rel :in *bench-lisp-source-files*
                        :for path := (merge-pathnames rel root)
                        :when (probe-file path)
                          :collect (uiop:read-file-string path)))
         (n (length sources)))
    (when (null sources)
      (error "no bench Lisp source files found under ~A" root))
    (with-output-to-string (out)
      (loop :for produced := 0 :then (+ produced (length chunk))
            :while (< produced +bench-lisp-target-bytes+)
            :for chunk := (nth (bench-rng-below rng n) sources)
            :do (write-string chunk out)
                (terpri out)))))

(defparameter *bench-cjk-code-points*
  (coerce (loop :for c :from #x4E00 :to #x4E7F :collect c) 'vector)
  "A block of common CJK unified ideographs (3-byte UTF-8 each).")

(defparameter *bench-emoji-code-points*
  #(#x1F600 #x1F601 #x1F602 #x1F609 #x1F60A #x1F60D #x1F914 #x1F44D
    #x1F525 #x1F389 #x1F680 #x2764 #x2728 #x1F4A9 #x1F92F #x1F971)
  "Emoji / pictographic code points (wide; some outside the BMP).")

(defparameter *bench-combining-code-points*
  (coerce (loop :for c :from #x0300 :to #x036F :collect c) 'vector)
  "Combining diacritical marks (zero-width; attach to the preceding base).")

(defparameter *bench-ascii-code-points*
  (coerce (loop :for c :from 32 :to 126 :collect c) 'vector)
  "Printable ASCII.")

(defun bench-build-unicode-mixed ()
  "Deterministically interleave ASCII, CJK, emoji, and combining marks into
newline-separated lines until the byte target is reached."
  (let ((rng (bench-make-rng #xC0DEC0DEC0DE0002))
        (buffer (make-string-output-stream))
        (bytes 0))
    (flet ((emit (code)
             (let ((ch (code-char code)))
               (write-char ch buffer)
               ;; UTF-8 byte length, so the target tracks the on-disk size.
               (incf bytes (cond ((< code #x80) 1)
                                 ((< code #x800) 2)
                                 ((< code #x10000) 3)
                                 (t 4))))))
      (loop :while (< bytes +bench-unicode-target-bytes+)
            :for line-len := (+ 20 (bench-rng-below rng 60))
            :do (dotimes (i line-len)
                  (case (bench-rng-below rng 8)
                    ((0 1 2) (emit (bench-rng-element rng *bench-ascii-code-points*)))
                    ((3 4)   (emit (bench-rng-element rng *bench-cjk-code-points*)))
                    (5       (emit (bench-rng-element rng *bench-emoji-code-points*)))
                    (6       ;; base ASCII carrying a combining mark
                             (emit (bench-rng-element rng *bench-ascii-code-points*))
                             (emit (bench-rng-element rng *bench-combining-code-points*)))
                    (7       (emit (bench-rng-element rng *bench-cjk-code-points*)))))
                (write-char #\newline buffer)
                (incf bytes)))
    (get-output-stream-string buffer)))

(defun bench-build-long-line-200k ()
  "A single deterministic printable-ASCII line of +bench-long-line-length+
characters, no trailing newline."
  (let ((rng (bench-make-rng #xFEEDFACE00000003))
        (s (make-string +bench-long-line-length+)))
    (dotimes (i +bench-long-line-length+ s)
      (setf (char s i) (code-char (bench-rng-element rng *bench-ascii-code-points*))))))

(defun bench-corpus-content (name)
  (let ((key (bench-corpus-name-string name)))
    (cond ((string= key "lisp-500k") (bench-build-lisp-500k))
          ((string= key "unicode-mixed") (bench-build-unicode-mixed))
          ((string= key "long-line-200k") (bench-build-long-line-200k))
          (t (error "unknown bench corpus: ~A" name)))))

;;;; ------------------------------------------------------------------
;;;; Generation / caching
;;;; ------------------------------------------------------------------

(defun bench-ensure-corpus (name)
  "Return the cache pathname for corpus NAME, generating it deterministically
on first use.  A present non-empty file is trusted (content is a pure function
of committed inputs)."
  (let ((path (bench-corpus-path name)))
    (unless (and (probe-file path)
                 (plusp (with-open-file (in path) (file-length in))))
      (ensure-directories-exist path)
      (let ((content (bench-corpus-content name)))
        (with-open-file (out path :direction :output
                                  :if-exists :supersede
                                  :if-does-not-exist :create
                                  :external-format :utf-8)
          (write-string content out))))
    path))

(defun bench-ensure-all-corpora ()
  "Generate (or reuse) every corpus, print a one-line summary per corpus, and
return an alist of (name . pathname).  Exercises all generators on every bench
run so a broken generator fails loudly."
  (loop :for (key . nil) :in *bench-corpus-files*
        :for path := (bench-ensure-corpus key)
        :do (format t "~&corpus ~16A -> ~A (~D bytes)~%"
                    key path (with-open-file (in path) (file-length in)))
        :collect (cons key path)))
