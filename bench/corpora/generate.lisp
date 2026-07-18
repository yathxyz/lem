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
;;;;                   only, so the result is valid by construction).  Read from
;;;;                   the FIXED pin commit via `git show', NOT the working tree
;;;;                   (see +bench-lisp-pin+ below), so the corpus does not drift
;;;;                   under the very optimizations SPEC-PERF P5 makes to those
;;;;                   files.
;;;;   :unicode-mixed  ~100 KB of mixed ASCII / CJK / emoji / combining-mark text
;;;;                   (the kernel string-width path's corpus).
;;;;   :long-line-200k  a single 200 000-char line, no newline (the PI-1 corpus
;;;;                   the edit/points benchmarks stress).
;;;;   :mixed-10m      ~10 MB deterministic prose+code mix, mixed line lengths,
;;;;                   some unicode -- the T2 big-file workload corpus (PF-5).
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

(defparameter +bench-lisp-pin+ "5cd018a9"
  "The FIXED commit the `lisp-500k' corpus is built from.  Its source files are
read via `git show <pin>:<path>' -- the git object store, independent of the
working tree -- so the corpus is byte-stable across the SPEC-PERF P5
optimizations that will edit those same files, and two regenerations are always
identical.  The pin is baked into the lisp-500k cache filename below, so bumping
it invalidates the cache automatically (cache invalidation keyed on the pin).")

(defparameter *bench-corpus-files*
  `(("lisp-500k"      . ,(format nil "lisp-500k-~A.lisp" +bench-lisp-pin+))
    ("unicode-mixed"  . "unicode-mixed.txt")
    ("long-line-200k" . "long-line-200k.txt")
    ("mixed-10m"      . "mixed-10m.txt"))
  "Corpus name -> cache filename.  The lisp-500k filename carries the pin commit
so a pin bump lands in a fresh cache file (see +bench-lisp-pin+).")

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
  "Repo files concatenated (whole, so the result parses) to build the Lisp
corpus.  Read at the +bench-lisp-pin+ commit, not the working tree -> the corpus
bytes are a pure function of committed history, so the fixed list yields
deterministic bytes that do not drift when these files are later optimized.")

(defparameter +bench-lisp-target-bytes+ (* 500 1024))
(defparameter +bench-unicode-target-bytes+ (* 100 1024))
(defparameter +bench-long-line-length+ 200000)

(defun bench-git-show (rel)
  "Return the contents of REL (a repo-relative path) at the +bench-lisp-pin+
commit via `git show', reading the git object store rather than the working
tree.  Errors loudly if git or the pinned object is unavailable."
  (multiple-value-bind (out err code)
      (uiop:run-program (list "git" "show" (format nil "~A:~A" +bench-lisp-pin+ rel))
                        :output :string
                        :error-output :string
                        :directory (bench-repo-root)
                        :ignore-error-status t)
    (unless (zerop code)
      (error "git show ~A:~A failed (exit ~D): ~A" +bench-lisp-pin+ rel code err))
    out))

(defun bench-build-lisp-500k ()
  "Concatenate whole repo source files (read at the fixed pin commit) in a
deterministic (seeded) order, repeating until the byte target is reached.
Appending only whole files keeps the corpus syntactically valid by construction;
reading at the pin (not the working tree) keeps it byte-stable across the P5
optimizations that will edit those files."
  (let* ((rng (bench-make-rng #xB1A5E115F0000001))   ; distinct fixed seed per corpus
         (sources (mapcar #'bench-git-show *bench-lisp-source-files*))
         (n (length sources)))
    (when (null sources)
      (error "no bench Lisp source files configured"))
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

;;;; ------------------------------------------------------------------
;;;; mixed-10m: ~10 MB realistic prose + code mix (the T2 big-file corpus)
;;;; ------------------------------------------------------------------

(defparameter +bench-mixed-target-bytes+ (* 10 1024 1024)
  "Byte target for the mixed-10m corpus (~10 MB, tracked as UTF-8 bytes).")

(defparameter *bench-prose-words*
  #("the" "a" "buffer" "point" "window" "editor" "line" "cursor" "text" "mode"
    "region" "overlay" "syntax" "frame" "command" "keymap" "display" "kernel"
    "insert" "delete" "move" "search" "render" "scan" "width" "column" "byte"
    "when" "then" "returns" "value" "state" "each" "over" "with" "into" "from"
    "position" "character" "string" "list" "table" "index" "count" "offset"
    "and" "or" "but" "if" "while" "for" "every" "some" "all" "none" "must"
    "shall" "may" "will" "does" "keeps" "holds" "walks" "folds" "clips" "wraps")
  "Common lowercase prose words (deterministic sentence filler).")

(defparameter *bench-code-heads*
  #("defun" "defvar" "defparameter" "defmethod" "defclass" "let" "let*" "when"
    "unless" "dolist" "dotimes" "loop" "lambda" "setf" "incf" "return-from"
    "handler-case" "with-open-file" "multiple-value-bind" "destructuring-bind")
  "Lisp form heads for the code-line generator.")

(defparameter *bench-code-syms*
  #("point" "buffer" "window" "char" "line" "count" "index" "start" "end" "pos"
    "value" "state" "result" "acc" "n" "i" "x" "y" "col" "row" "width" "offset"
    "node" "table" "list" "string" "region" "overlay" "attribute" "cache")
  "Lisp identifiers for the code-line generator.")

(defparameter *bench-mixed-unicode*
  (coerce (mapcar #'code-char
                  '(#x03BB #x03B1 #x03B2   ; Greek lambda / alpha / beta
                    #x00E9 #x00F6 #x00F1   ; accented Latin: e-acute o-diaer n-tilde
                    #x2192 #x2022 #x2014 #x2260 ; arrow, bullet, em-dash, not-equal
                    #x4E2D #x6587))        ; CJK ideographs
          'vector)
  "Occasional non-ASCII glyphs sprinkled into prose (accented Latin, Greek, math
arrows, CJK) -- exercises the width kernel's multibyte path on the big file.
Given as code points so the file reads without depending on SBCL char names.")

(defun bench-mixed-emit-word (rng out utf8-count pool)
  "Write a random word from POOL to OUT, optionally suffixing one unicode glyph,
and return the running UTF-8 byte count including a trailing space."
  (let ((word (bench-rng-element rng pool)))
    (write-string word out)
    (incf utf8-count (length word))          ; pool words are ASCII
    (when (zerop (bench-rng-below rng 40))    ; ~2.5% of words carry a glyph
      (let ((ch (bench-rng-element rng *bench-mixed-unicode*)))
        (write-char ch out)
        (incf utf8-count (cond ((< (char-code ch) #x80) 1)
                               ((< (char-code ch) #x800) 2)
                               ((< (char-code ch) #x10000) 3)
                               (t 4)))))
    (write-char #\Space out)
    (1+ utf8-count)))

(defun bench-mixed-prose-line (rng out)
  "One prose line of a random word count; return its UTF-8 byte length (incl.
the newline)."
  (let ((words (+ 4 (bench-rng-below rng 18)))
        (bytes 0))
    (dotimes (i words)
      (setf bytes (bench-mixed-emit-word rng out bytes *bench-prose-words*)))
    (write-char #\Newline out)
    (1+ bytes)))

(defun bench-mixed-code-line (rng out)
  "One lisp-ish code line with leading indentation and parens; return its UTF-8
byte length (incl. the newline).  Pure ASCII, so byte length = character count."
  (let* ((indent (* 2 (bench-rng-below rng 5)))
         (args (1+ (bench-rng-below rng 4)))
         (head (bench-rng-element rng *bench-code-heads*))
         (bytes 0))
    (dotimes (i indent) (write-char #\Space out))
    (incf bytes indent)
    (write-char #\( out)
    (write-string head out)
    (write-char #\Space out)
    (incf bytes (+ 2 (length head)))          ; "(" + head + " "
    (dotimes (i args)
      (let ((sym (bench-rng-element rng *bench-code-syms*)))
        (write-string sym out)
        (write-char #\Space out)
        (incf bytes (1+ (length sym)))))       ; sym + " "
    (write-char #\) out)
    (write-char #\Newline out)
    (+ bytes 2)))                              ; ")" + newline

(defun bench-build-mixed-10m ()
  "Deterministically interleave prose paragraphs, lisp-ish code blocks, blank
lines, and occasional unicode into a ~10 MB multi-line document.  Line lengths
vary (short code lines to long prose lines); the byte target tracks UTF-8 size."
  (let ((rng (bench-make-rng #x10ADED00DEC0FFEE))
        (bytes 0))
    (with-output-to-string (out)
      (loop :while (< bytes +bench-mixed-target-bytes+)
            :do (case (bench-rng-below rng 10)
                  ((0 1 2 3)                       ; prose paragraph (3-8 lines)
                   (dotimes (i (+ 3 (bench-rng-below rng 6)))
                     (incf bytes (bench-mixed-prose-line rng out)))
                   (write-char #\Newline out)
                   (incf bytes))
                  ((4 5 6 7)                       ; code block (4-12 lines)
                   (dotimes (i (+ 4 (bench-rng-below rng 9)))
                     (incf bytes (bench-mixed-code-line rng out)))
                   (write-char #\Newline out)
                   (incf bytes))
                  (t                               ; a lone short line
                   (incf bytes (bench-mixed-prose-line rng out))))))))

(defun bench-corpus-content (name)
  (let ((key (bench-corpus-name-string name)))
    (cond ((string= key "lisp-500k") (bench-build-lisp-500k))
          ((string= key "unicode-mixed") (bench-build-unicode-mixed))
          ((string= key "long-line-200k") (bench-build-long-line-200k))
          ((string= key "mixed-10m") (bench-build-mixed-10m))
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
