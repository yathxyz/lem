(defpackage :lem-tests/pbt/harness
  (:use :cl)
  (:documentation
   "In-repo property-based-testing harness for the Lem verified kernel (SPEC-VK
V0-4). Provides a deterministic private PRNG (SplitMix64), value generators with
shrinkers, greedy counterexample shrinking, and a `for-all' driver that reports
property failures as rove failures. No external PBT dependency.")
  ;; PRNG
  (:export :make-rng
           :next-u64
           :rng-below
           :rng-range
           :rng-boolean
           :rng-element)
  ;; Generators and combinators
  (:export :make-generator
           :generator
           :generator-sample
           :generator-shrink
           :draw
           :gen-integer
           :gen-boolean
           :gen-character
           :gen-string
           :gen-list
           :gen-byte-stream
           :gen-buffer-content
           :gen-edit-op
           :gen-edit-script
           :buffer-content->string)
  ;; Driver and result reporting
  (:export :for-all
           :check-property
           :default-seed
           :property-failure-report
           :property-summary
           :property-result
           :property-result-passed
           :property-result-seed
           :property-result-name
           :property-result-num-tests-run
           :property-result-original
           :property-result-shrunk
           :property-result-shrink-steps
           :property-result-condition)
  ;; Tunables
  (:export :*num-tests*
           :*seed*
           :*seed-env-var*))
(in-package :lem-tests/pbt/harness)

;;; ------------------------------------------------------------------
;;; Parameters and constants
;;; ------------------------------------------------------------------

(defconstant +u64-mask+ #xFFFFFFFFFFFFFFFF
  "Mask for 64-bit unsigned arithmetic.")

(defconstant +max-shrink-steps+ 1000
  "Upper bound on greedy shrink iterations, a termination safety net.")

(defvar *num-tests* 100
  "Number of random cases `check-property' draws per property by default.")

(defvar *seed* nil
  "When non-NIL, the seed `check-property' uses instead of `default-seed'.")

(defparameter *seed-env-var* "LEM_PBT_SEED"
  "Environment variable read by `default-seed' to force a reproducing seed.")

;; Character pools for the Unicode string generator. Together they exercise
;; multibyte code points, combining marks, and emoji (incl. ZWJ / variation
;; selector) as required by V0-4.
(defparameter *ascii-code-points*
  (coerce (loop :for c :from 32 :to 126 :collect c) 'vector)
  "Printable ASCII code points.")

(defparameter *latin1-code-points*
  #(#xE9 #xF1 #xFC #xDF #xE0 #xE7 #xC5 #xF8)
  "A sample of Latin-1 accented code points (two UTF-8 bytes each).")

(defparameter *cjk-code-points*
  #(#x3042 #x3044 #x4E2D #x6587 #xAC00 #xD55C #x1F1)
  "A sample of wide CJK / Hangul code points (multibyte).")

(defparameter *combining-code-points*
  #(#x0300 #x0301 #x0308 #x0323 #x0327 #x0489)
  "Combining marks that attach to a preceding base character.")

(defparameter *emoji-code-points*
  #(#x1F600 #x1F602 #x1F609 #x1F308 #x1F44D #x1F468 #x1F469 #x1F9D1
    #x200D #x2764 #xFE0F)
  "Emoji plus the zero-width joiner and variation selector so ZWJ sequences form.")

;;; ------------------------------------------------------------------
;;; Structures
;;; ------------------------------------------------------------------

(defstruct (rng (:constructor make-rng (seed &aux (state (logand seed +u64-mask+)))))
  "SplitMix64 pseudo-random generator. Seeded from an honest integer so runs are
byte-for-byte reproducible across images (CL's `make-random-state' cannot)."
  (state 0 :type (unsigned-byte 64)))

(defstruct (generator (:constructor make-generator (&key sample shrink)))
  "A value generator: SAMPLE draws a value from an `rng'; SHRINK maps a value to a
list of strictly-smaller candidate values (most aggressive first)."
  (sample (error "generator requires :sample") :type function)
  (shrink (constantly nil) :type function))

(defstruct property-result
  "Outcome of `check-property': whether the property held, the seed used, and — on
failure — the original and shrunk counterexamples."
  (passed nil)
  (seed 0)
  (name nil)
  (num-tests-run 0)
  (original nil)
  (shrunk nil)
  (shrink-steps 0)
  (condition nil))

;;; ------------------------------------------------------------------
;;; PRNG
;;; ------------------------------------------------------------------

(defun next-u64 (rng)
  "Advance RNG and return the next 64-bit unsigned value (SplitMix64)."
  (let ((z (setf (rng-state rng)
                 (logand (+ (rng-state rng) #x9E3779B97F4A7C15) +u64-mask+))))
    (setf z (logand (* (logxor z (ash z -30)) #xBF58476D1CE4E5B9) +u64-mask+))
    (setf z (logand (* (logxor z (ash z -27)) #x94D049BB133111EB) +u64-mask+))
    (logxor z (ash z -31))))

(defun rng-below (rng n)
  "Return a pseudo-random integer in [0, N) drawn from RNG; 0 when N <= 1."
  (if (<= n 1) 0 (mod (next-u64 rng) n)))

(defun rng-range (rng min max)
  "Return a pseudo-random integer in the inclusive range [MIN, MAX] from RNG."
  (+ min (rng-below rng (1+ (- max min)))))

(defun rng-boolean (rng)
  "Return a pseudo-random boolean from RNG."
  (oddp (next-u64 rng)))

(defun rng-element (rng sequence)
  "Return a pseudo-random element of the non-empty SEQUENCE using RNG."
  (elt sequence (rng-below rng (length sequence))))

(defun default-seed ()
  "The seed for a fresh run: the integer in `*seed-env-var*' if set, else a fresh
OS-entropy seed (so a failure can later be reproduced by exporting that variable)."
  (let ((env (uiop:getenv *seed-env-var*)))
    (or (and env (ignore-errors
                  (parse-integer (string-trim '(#\Space #\Tab #\Newline) env))))
        (random (expt 2 63) (make-random-state t)))))

;;; ------------------------------------------------------------------
;;; Shrinking primitives
;;; ------------------------------------------------------------------

(defun replace-nth (list index new)
  "A fresh copy of LIST with position INDEX replaced by NEW."
  (loop :for i :from 0 :for x :in list :collect (if (= i index) new x)))

(defun dedupe-keep-order (candidates original &key (test #'equal))
  "Remove ORIGINAL and duplicate entries from CANDIDATES, keeping first occurrence."
  (let ((seen '())
        (result '()))
    (dolist (c candidates (nreverse result))
      (unless (or (funcall test c original)
                  (member c seen :test test))
        (push c seen)
        (push c result)))))

(defun shrink-integer (n target)
  "Candidates shrinking N toward TARGET by binary reduction (TARGET first)."
  (if (= n target)
      '()
      (let ((cands (list target))
            (diff (- n target)))
        (loop :for d = (truncate diff 2) :then (truncate d 2)
              :while (/= d 0)
              :do (let ((c (- n d)))
                    (unless (= c target) (push c cands))))
        (nreverse cands))))

(defun shrink-string (string)
  "Candidates shrinking STRING: empty, halves, each single-char deletion, then each
character simplified to #\\a. CL characters are full code points, so emoji and
combining marks each shrink as one unit."
  (let ((n (length string)))
    (dedupe-keep-order
     (append
      (when (plusp n) (list ""))
      (when (> n 1)
        (list (subseq string 0 (truncate n 2))
              (subseq string (truncate n 2))))
      (loop :for i :below n
            :collect (concatenate 'string (subseq string 0 i) (subseq string (1+ i))))
      (loop :for i :below n
            :for ch = (char string i)
            :when (char/= ch #\a)
            :collect (let ((copy (copy-seq string)))
                       (setf (char copy i) #\a)
                       copy)))
     string :test #'string=)))

(defun shrink-list (list element-shrink)
  "Candidates shrinking LIST: empty, halves, each single-element deletion, then each
element replaced by one of its ELEMENT-SHRINK candidates."
  (let ((n (length list)))
    (dedupe-keep-order
     (append
      (when (plusp n) (list '()))
      (when (> n 1)
        (list (subseq list 0 (truncate n 2))
              (subseq list (truncate n 2))))
      (loop :for i :below n
            :collect (append (subseq list 0 i) (subseq list (1+ i))))
      (loop :for i :below n
            :for elt = (nth i list)
            :nconc (loop :for s :in (funcall element-shrink elt)
                         :collect (replace-nth list i s))))
     list)))

;;; ------------------------------------------------------------------
;;; Generators
;;; ------------------------------------------------------------------

(defun draw (generator rng)
  "Draw one value from GENERATOR using RNG."
  (funcall (generator-sample generator) rng))

(defun gen-integer (&key (min 0) (max 1000))
  "A generator of integers in the inclusive range [MIN, MAX], shrinking toward the
simplest in-range value (0 when possible, otherwise MIN)."
  (let ((target (if (<= min 0 max) 0 min)))
    (make-generator
     :sample (lambda (rng) (rng-range rng min max))
     :shrink (lambda (n) (shrink-integer n target)))))

(defun gen-boolean ()
  "A generator of booleans, shrinking T toward NIL."
  (make-generator
   :sample #'rng-boolean
   :shrink (lambda (b) (if b (list nil) '()))))

(defun random-character (rng alphabet)
  "Draw one character from RNG. ALPHABET is :ascii or :unicode; :unicode mixes
ASCII, Latin-1, CJK, combining marks and emoji."
  (code-char
   (if (eq alphabet :ascii)
       (rng-element rng *ascii-code-points*)
       (let ((r (rng-below rng 100)))
         (rng-element rng
                      (cond ((< r 55) *ascii-code-points*)
                            ((< r 65) *latin1-code-points*)
                            ((< r 80) *cjk-code-points*)
                            ((< r 90) *combining-code-points*)
                            (t *emoji-code-points*)))))))

(defun gen-character (&key (alphabet :unicode))
  "A generator of characters over ALPHABET (:unicode or :ascii), shrinking to #\\a."
  (make-generator
   :sample (lambda (rng) (random-character rng alphabet))
   :shrink (lambda (ch) (if (char= ch #\a) '() (list #\a)))))

(defun gen-string (&key (min-length 0) (max-length 20) (alphabet :unicode))
  "A generator of strings of length [MIN-LENGTH, MAX-LENGTH] over ALPHABET. With the
default :unicode alphabet the repertoire includes multibyte, combining and emoji
characters."
  (make-generator
   :sample (lambda (rng)
             (let ((len (rng-range rng min-length max-length)))
               (with-output-to-string (out)
                 (dotimes (i len)
                   (write-char (random-character rng alphabet) out)))))
   :shrink #'shrink-string))

(defun gen-list (element-gen &key (min-length 0) (max-length 10))
  "A generator of lists of [MIN-LENGTH, MAX-LENGTH] elements drawn from ELEMENT-GEN."
  (make-generator
   :sample (lambda (rng)
             (loop :repeat (rng-range rng min-length max-length)
                   :collect (draw element-gen rng)))
   :shrink (lambda (list) (shrink-list list (generator-shrink element-gen)))))

(defun gen-byte-stream (&key (min-length 0) (max-length 32))
  "A generator of (unsigned-byte 8) vectors of length [MIN-LENGTH, MAX-LENGTH]."
  (let ((byte-gen (gen-integer :min 0 :max 255)))
    (make-generator
     :sample (lambda (rng)
               (let* ((len (rng-range rng min-length max-length))
                      (v (make-array len :element-type '(unsigned-byte 8))))
                 (dotimes (i len v)
                   (setf (aref v i) (rng-below rng 256)))))
     :shrink (lambda (v)
               (mapcar (lambda (bytes)
                         (make-array (length bytes)
                                     :element-type '(unsigned-byte 8)
                                     :initial-contents bytes))
                       (shrink-list (coerce v 'list)
                                    (generator-shrink byte-gen)))))))

(defun gen-buffer-content (&key (max-lines 8) (max-line-length 20))
  "A generator of buffer contents as a list of line strings (no embedded newlines)."
  (gen-list (gen-string :max-length max-line-length) :max-length max-lines))

(defun buffer-content->string (lines)
  "Join buffer-content LINES into a single newline-separated string."
  (format nil "~{~A~^~%~}" lines))

(defun shrink-edit-op (op)
  "Candidates shrinking a single edit OP (see `gen-edit-op')."
  (destructuring-bind (kind pos arg) op
    (ecase kind
      (:insert
       (append
        (loop :for s :in (shrink-integer pos 0) :collect (list :insert s arg))
        (loop :for s :in (shrink-string arg) :collect (list :insert pos s))))
      (:delete
       (append
        (loop :for s :in (shrink-integer pos 0) :collect (list :delete s arg))
        (loop :for s :in (shrink-integer arg 1) :collect (list :delete pos s)))))))

(defun gen-edit-op (&key (max-pos 100) (max-insert 8) (max-delete 8))
  "A generator of a single edit operation as data: (:insert POS STRING) or
(:delete POS COUNT)."
  (let ((string-gen (gen-string :max-length max-insert)))
    (make-generator
     :sample (lambda (rng)
               (if (rng-boolean rng)
                   (list :insert (rng-range rng 0 max-pos) (draw string-gen rng))
                   (list :delete (rng-range rng 0 max-pos) (rng-range rng 1 max-delete))))
     :shrink #'shrink-edit-op)))

(defun gen-edit-script (&key (max-ops 12))
  "A generator of edit scripts: lists of up to MAX-OPS edit operations (data only)."
  (gen-list (gen-edit-op) :max-length max-ops))

;;; ------------------------------------------------------------------
;;; Property checking and shrinking
;;; ------------------------------------------------------------------

(defun property-fails-p (property values)
  "Run PROPERTY on the argument list VALUES. Return (values FAILED-P CONDITION):
FAILED-P is true when the property returns NIL or signals an error."
  (handler-case
      (values (not (funcall property values)) nil)
    (error (c) (values t c))))

(defun shrink-tuple (generators values)
  "All one-step shrinks of the argument tuple VALUES, shrinking each component in
turn with its generator's shrinker."
  (loop :for i :from 0
        :for gen :in generators
        :for val :in values
        :nconc (loop :for s :in (funcall (generator-shrink gen) val)
                     :collect (replace-nth values i s))))

(defun first-failing-shrink (generators property values)
  "The first one-step shrink of VALUES on which PROPERTY still fails, or NIL."
  (dolist (candidate (shrink-tuple generators values) nil)
    (when (property-fails-p property candidate)
      (return candidate))))

(defun shrink-counterexample (generators property values)
  "Greedily shrink the failing tuple VALUES. Return (values SHRUNK STEPS)."
  (let ((current values)
        (steps 0))
    (loop
      (let ((next (and (< steps +max-shrink-steps+)
                       (first-failing-shrink generators property current))))
        (if next
            (setf current next steps (1+ steps))
            (return (values current steps)))))))

(defun check-property (generators property
                       &key (num-tests *num-tests*)
                            (seed (or *seed* (default-seed)))
                            name)
  "Draw NUM-TESTS argument tuples from GENERATORS (a list) using SEED and apply
PROPERTY (a function of one argument, the tuple list). On the first failure, shrink
the counterexample and return a failing `property-result'; otherwise return a passing
one. PROPERTY passes on any non-NIL return and fails on NIL or a signalled error."
  (let ((rng (make-rng seed)))
    (dotimes (i num-tests
                (make-property-result :passed t :seed seed :name name
                                      :num-tests-run num-tests))
      (let ((values (mapcar (lambda (g) (draw g rng)) generators)))
        (multiple-value-bind (failed condition) (property-fails-p property values)
          (declare (ignore condition))
          (when failed
            (multiple-value-bind (shrunk steps)
                (shrink-counterexample generators property values)
              (return
                (make-property-result
                 :passed nil :seed seed :name name :num-tests-run (1+ i)
                 :original values :shrunk shrunk :shrink-steps steps
                 :condition (nth-value 1 (property-fails-p property shrunk)))))))))))

;;; ------------------------------------------------------------------
;;; Reporting and the rove-compatible driver
;;; ------------------------------------------------------------------

(defun property-summary (result)
  "A one-line description of a passing RESULT."
  (format nil "Property~@[ ~A~] held for ~D test(s) (seed ~D)."
          (property-result-name result)
          (property-result-num-tests-run result)
          (property-result-seed result)))

(defun property-failure-report (result)
  "A multi-line failure report for RESULT: seed (with reproduction hint), original
and shrunk counterexamples, and any signalled condition."
  (with-output-to-string (out)
    (format out "Property~@[ ~A~] FAILED after ~D test(s)."
            (property-result-name result)
            (property-result-num-tests-run result))
    (format out "~%  Seed:      ~D  (reproduce with ~A=~D)"
            (property-result-seed result)
            *seed-env-var*
            (property-result-seed result))
    (format out "~%  Original:  ~{~S~^ ~}" (property-result-original result))
    (format out "~%  Shrunk:    ~{~S~^ ~}  (~D shrink step(s))"
            (property-result-shrunk result)
            (property-result-shrink-steps result))
    (when (property-result-condition result)
      (format out "~%  Condition: ~A" (property-result-condition result)))))

(defun report-property-result (result)
  "Report RESULT to the active rove suite: `rove:pass' on success, or print the
failure report and `rove:fail' on failure. Return RESULT."
  (if (property-result-passed result)
      (rove:pass (property-summary result))
      (let ((report (property-failure-report result)))
        (format *error-output* "~&~A~%" report)
        (rove:fail report)))
  result)

(defmacro for-all ((&rest bindings) &body body)
  "Property driver usable inside a rove `deftest'. BINDINGS is a list of
(VAR GENERATOR-FORM); BODY is the property, evaluated with each VAR bound to a drawn
value and passing when it returns non-NIL. A failure becomes a rove failure whose
message carries the shrunk counterexample and reproducing seed."
  (let ((values (gensym "VALUES"))
        (vars (mapcar #'first bindings))
        (gens (mapcar #'second bindings)))
    `(report-property-result
      (check-property
       (list ,@gens)
       (lambda (,values) (destructuring-bind ,vars ,values ,@body))
       :name ',vars))))
