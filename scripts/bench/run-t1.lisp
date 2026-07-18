;;;; run-t1.lisp -- T1 micro-benchmark driver (SPEC-PERF PF-3 / PF-4).
;;;;
;;;; Loaded after `(ql:quickload :lem/core)` by `scripts/run-bench.sh`.  This
;;;; file is the tier harness only: measurement primitives, a multi-entry
;;;; registry, the noise-band gate, and the JSON schema.  The entries live one
;;;; per file next to this driver (`telemetry.lisp', `edit.lisp', `points.lisp',
;;;; ...); the driver discovers and loads every sibling `*.lisp' that is not a
;;;; `run-*.lisp' driver, and each file registers its entries via
;;;; `register-bench-entry'.  Corpora come from `bench/corpora/generate.lisp'.
;;;;
;;;; The runner passes configuration through the environment:
;;;;
;;;;   LEM_BENCH_MODE          "measure" | "rebaseline"
;;;;   LEM_BENCH_TIER          "t1"
;;;;   LEM_BENCH_FINGERPRINT   full machine/CPU fingerprint string
;;;;   LEM_BENCH_TIMESTAMP     YYYYMMDDHHMMSS (shared with the results filename)
;;;;   LEM_BENCH_FP_SLUG       filesystem-safe fingerprint slug
;;;;   LEM_BENCH_RESULTS_DIR   directory for result JSON files
;;;;   LEM_BENCH_BASELINES_DIR directory holding the committed baselines
;;;;   LEM_BENCH_ONLY          optional: comma-separated entry names to run
;;;;                              (the self-test scopes itself to "telemetry")
;;;;   LEM_BENCH_INJECT_SLEEP_US  optional: busy-wait this many us per telemetry
;;;;                              op (self-test hook: injects a synthetic
;;;;                              regression the budget gate must catch)
;;;;
;;;; Measurement obeys SPEC-PERF Constraint 5: `gc :full' before each timed
;;;; section, one warm-up repetition discarded, median of five in-process
;;;; repetitions, reporting min/median/p90 plus bytes-consed/op.  Each entry
;;;; rebuilds its fixture per timed section (via its `:setup'), so every
;;;; repetition starts from an identical state and the numbers are reproducible
;;;; (SPEC-PERF PF-4: entries must be gate-stable).  Entries size their own
;;;; iteration counts so the timed window is >= 10 ms (PF-3: us-scale windows
;;;; go bimodal under the 1 us clock).

(in-package :cl-user)

;;;; ------------------------------------------------------------------
;;;; Environment helpers
;;;; ------------------------------------------------------------------

(defun bench-getenv (name)
  (let ((v (uiop:getenv name)))
    (if (and v (plusp (length v))) v nil)))

(defun bench-getenv-int (name)
  (let ((v (bench-getenv name)))
    (and v (ignore-errors (parse-integer v)))))

(defparameter *inject-sleep-us* (bench-getenv-int "LEM_BENCH_INJECT_SLEEP_US")
  "When non-nil, the telemetry op busy-waits this many microseconds per op,
standing in for a real slowdown so the gate machinery can be self-tested.")

(defparameter *bench-only*
  (let ((v (bench-getenv "LEM_BENCH_ONLY")))
    (and v (loop :for start := 0 :then (1+ pos)
                 :for pos := (position #\, v :start start)
                 :collect (string-trim " " (subseq v start pos))
                 :while pos)))
  "When non-nil, the list of entry names to run (others are skipped).  The
self-test uses this to scope itself to the budget-gated telemetry entry.")

;;;; ------------------------------------------------------------------
;;;; Budget-gated entries (Constraint 4, permanent)
;;;; ------------------------------------------------------------------

(defparameter +budget-gated-entries+ '("telemetry")
  "Entries whose regression gate is the Constraint-4 hard budget (< 1 us/op AND
0 bytes consed/op, enforced permanently by `budget-violations'), NOT the
median-vs-noise-band comparison.  The record path costs ~0.8 ns/op, an order of
magnitude below `get-internal-real-time' resolution and far below the
between-process CPU-frequency variance a real pre-commit machine exhibits (a
busy machine intermittently reads +50%).  A median-band gate on such an entry
is non-reproducible: it intermittently reports false regressions that would
block legitimate commits, while a real regression this path could suffer either
conses (caught by the 0-consed budget) or adds latency pushing it over the 1 us
budget.  So the hard budget is the deterministic, meaningful gate; the band
comparison is reported for trend only.  All us-scale entries (edit, points, ...)
default to the normal band gate, where it is sound.")

(defun budget-gated-p (name)
  "True when the entry NAME is gated by the hard budget, not the noise band."
  (and (member name +budget-gated-entries+ :test #'string=) t))

;;;; ------------------------------------------------------------------
;;;; Entry registry
;;;; ------------------------------------------------------------------

(defstruct bench-entry
  "One registered T1 entry.  SETUP is a thunk of no args returning a per-section
fixture (state); OP is a function of (state count) performing COUNT ops on that
state.  SETUP runs untimed before every timed section, so each repetition starts
from an identical state.  INNER is the op count (sized for a >= 10 ms window)."
  (name "" :type string)
  (unit "us/op" :type string)
  (inner 1 :type (integer 1))
  (setup (lambda () nil) :type function)
  (op (lambda (state count) (declare (ignore state count))) :type function))

(defvar *bench-entries* '()
  "Registered entries in registration order (see `bench-entries').")

(defun register-bench-entry (&key name unit inner setup op)
  "Register (or, by NAME, replace) a T1 entry.  Called from the entry files at
load time.  Replacing keeps the original position so ordering stays stable
across a reload."
  (let ((entry (make-bench-entry :name name
                                 :unit (or unit "us/op")
                                 :inner inner
                                 :setup setup
                                 :op op))
        (existing (find name *bench-entries* :key #'bench-entry-name :test #'string=)))
    (if existing
        (setf *bench-entries* (substitute entry existing *bench-entries*))
        (setf *bench-entries* (append *bench-entries* (list entry))))
    entry))

(defun bench-entries ()
  "The entries to run, honouring LEM_BENCH_ONLY."
  (if *bench-only*
      (remove-if-not (lambda (e) (member (bench-entry-name e) *bench-only* :test #'string=))
                     *bench-entries*)
      *bench-entries*))

;;;; ------------------------------------------------------------------
;;;; Discovery / loading of entry files and corpora
;;;; ------------------------------------------------------------------

(defparameter *bench-source-dir*
  (uiop:pathname-directory-pathname (or *load-truename* *default-pathname-defaults*))
  "Directory holding this driver (scripts/bench/).")

(defun bench-load-corpora ()
  "Load the corpus generator (bench/corpora/generate.lisp) and eagerly generate
(or reuse) every corpus, so a broken generator fails loudly on every run.  The
generator is loaded at runtime, so its functions are reached via `find-symbol'
to avoid a compile-time forward reference."
  (let* ((root (uiop:pathname-parent-directory-pathname
                (uiop:pathname-parent-directory-pathname *bench-source-dir*)))
         (gen (merge-pathnames "bench/corpora/generate.lisp" root)))
    (load gen)
    (funcall (or (find-symbol "BENCH-ENSURE-ALL-CORPORA" :cl-user)
                 (error "corpus generator did not define bench-ensure-all-corpora")))))

(defun bench-load-entry-files ()
  "Load every sibling `*.lisp' entry file (all but the `run-*.lisp' drivers),
in a deterministic sorted order so registration order is stable."
  (dolist (path (sort (directory (merge-pathnames "*.lisp" *bench-source-dir*))
                      #'string< :key #'namestring))
    (let ((name (pathname-name path)))
      (unless (and (>= (length name) 4) (string= (subseq name 0 4) "run-"))
        (load path)))))

;;;; ------------------------------------------------------------------
;;;; Measurement primitives
;;;; ------------------------------------------------------------------

(defun bench-busy-us (us)
  "Busy-wait for approximately US microseconds on the process-wide monotonic
clock.  Used only by the telemetry self-test injection path."
  (declare (type fixnum us))
  (let ((end (+ (get-internal-real-time)
                (truncate (* us internal-time-units-per-second) 1000000))))
    (loop :while (< (get-internal-real-time) end))))

(defparameter +bench-nursery-bytes+ (* 1024 1024 1024)
  "Allocation budget between GCs during measurement (1 GiB).  A timed section
starts with a full GC (small live set: one benchmark buffer) and then conses at
most ~65 MB (the heaviest entry, longline release insert), so with a 1 GiB
budget no GC fires inside a timed window.  This removes GC-pause jitter -- the
dominant between-run noise for the consing-heavy edit/points entries, seen
doubling a 25 ms window -- from the wall-time figure; the allocation itself is
reported separately as consed-per-op (and GC cost lives in T0/T3, not T1).  The
per-section full GC keeps total heap bounded despite the raised threshold.")

(setf (sb-ext:bytes-consed-between-gcs) +bench-nursery-bytes+)

(defun time-section (state op inner)
  "Run OP over INNER iterations on STATE after a full GC; return microseconds
per op as a double-float."
  (sb-ext:gc :full t)
  (let ((t0 (get-internal-real-time)))
    (funcall op state inner)
    (let ((elapsed (- (get-internal-real-time) t0)))
      (/ (* (float elapsed 1d0) 1000000d0)
         (float internal-time-units-per-second 1d0)
         (float inner 1d0)))))

(defun consed-section (state op inner)
  "Bytes consed per op while running OP over INNER iterations on STATE.
Deliberately does NOT force a GC first (post-GC TLAB accounting would add a
fixed offset that hides the true per-op figure)."
  (let ((before (sb-ext:get-bytes-consed)))
    (funcall op state inner)
    (floor (- (sb-ext:get-bytes-consed) before) inner)))

(defun sorted-stat (samples fraction)
  "The FRACTION percentile of SAMPLES (a non-empty list) by nearest-rank."
  (let* ((sorted (sort (copy-list samples) #'<))
         (n (length sorted))
         (idx (min (1- n) (max 0 (1- (ceiling (* fraction n)))))))
    (nth idx sorted)))

(defparameter +bench-reps+ 9
  "Timed repetitions per entry (SPEC-PERF Constraint 5 mandates >= 5).  Nine
lets the median reject a transient load spike covering one or two reps.")

(defun measure-entry-section (entry)
  "One timed section of ENTRY: fresh fixture (untimed) then a timed run.
Returns us/op."
  (time-section (funcall (bench-entry-setup entry))
                (bench-entry-op entry)
                (bench-entry-inner entry)))

(defun run-suite ()
  "Measure every active entry and return the list of result plists (PF-3
schema).  Repetitions are INTERLEAVED across entries: one warm-up pass
(discarded), then +bench-reps+ round-robin passes, then one bytes-consed pass.
Interleaving spreads each entry's reps across the whole ~10 s suite, so a
sub-second load transient lands on at most one rep per entry and cannot drag an
entry's median -- the failure mode a back-to-back per-entry loop suffers when
the transient covers that entry's entire window."
  (let* ((entries (bench-entries))
         (samples (make-hash-table :test 'eq)))
    (dolist (e entries)                       ; warm-up pass, discarded
      (measure-entry-section e))
    (dotimes (rep +bench-reps+)                ; interleaved timed passes
      (dolist (e entries)
        (push (measure-entry-section e) (gethash e samples))))
    (mapcar (lambda (e)
              (let ((s (gethash e samples))
                    (consed (consed-section (funcall (bench-entry-setup e))
                                            (bench-entry-op e)
                                            (bench-entry-inner e))))
                (list :name (bench-entry-name e)
                      :unit (bench-entry-unit e)
                      :min (reduce #'min s)
                      :median (sorted-stat s 0.50)
                      :p90 (sorted-stat s 0.90)
                      :consed-per-op consed
                      :n (bench-entry-inner e))))
            entries)))

;;;; ------------------------------------------------------------------
;;;; Budgets (Constraint 4, permanent)
;;;; ------------------------------------------------------------------

(defun budget-violations (entries)
  "Return a list of human-readable budget-violation strings for ENTRIES.  The
`telemetry' entry must stay under 1 us/op and cons nothing."
  (let ((violations '()))
    (dolist (e entries (nreverse violations))
      (when (string= (getf e :name) "telemetry")
        (when (>= (getf e :median) 1d0)
          (push (format nil "telemetry median ~,4F us/op exceeds the 1 us budget"
                        (getf e :median))
                violations))
        (when (plusp (getf e :consed-per-op))
          (push (format nil "telemetry consed ~D bytes/op, budget is 0"
                        (getf e :consed-per-op))
                violations))))))

;;;; ------------------------------------------------------------------
;;;; JSON I/O
;;;; ------------------------------------------------------------------

(defun encode-entry (e &key band-p)
  (yason:with-object ()
    (yason:encode-object-element "name" (getf e :name))
    (yason:encode-object-element "unit" (getf e :unit))
    (yason:encode-object-element "min" (getf e :min))
    (yason:encode-object-element "median" (getf e :median))
    (yason:encode-object-element "p90" (getf e :p90))
    (yason:encode-object-element "consed-per-op" (getf e :consed-per-op))
    (yason:encode-object-element "n" (getf e :n))
    (when band-p
      (yason:encode-object-element "band" (getf e :band)))))

(defun write-results-json (path fingerprint tier commit timestamp entries
                           &key band-p)
  "Write ENTRIES to PATH in the PF-3 result schema.  When BAND-P, each entry
carries its noise band (baseline files only)."
  (with-open-file (out path :direction :output
                            :if-exists :supersede
                            :if-does-not-exist :create)
    (yason:with-output (out :indent t)
      (yason:with-object ()
        (yason:encode-object-element "fingerprint" fingerprint)
        (yason:encode-object-element "tier" tier)
        (yason:encode-object-element "commit" (or commit "unknown"))
        (yason:encode-object-element "timestamp" timestamp)
        (yason:with-object-element ("entries")
          (yason:with-array ()
            (dolist (e entries)
              (encode-entry e :band-p band-p))))))))

(defun read-baseline (path)
  "Parse the baseline JSON at PATH into a hash-table, or NIL if absent."
  (with-open-file (in path :if-does-not-exist nil)
    (and in (yason:parse in :object-as :hash-table))))

;;;; ------------------------------------------------------------------
;;;; Comparison / gating
;;;; ------------------------------------------------------------------

(defun baseline-entry-map (baseline)
  "name -> baseline-entry hash-table."
  (let ((map (make-hash-table :test 'equal)))
    (dolist (be (gethash "entries" baseline) map)
      (setf (gethash (gethash "name" be) map) be))))

(defun compare-and-gate (entries baseline fingerprint)
  "Print a delta table comparing ENTRIES against BASELINE and return T if any
gated entry regressed beyond its noise band (T1 is a gated tier)."
  (let ((base-fp (gethash "fingerprint" baseline)))
    (unless (equal base-fp fingerprint)
      (format t "~&REFUSING TO GATE: baseline fingerprint~%  [~A]~%~
                 does not match this machine~%  [~A]~%~
                 (Constraint 5: comparisons only run on a matching fingerprint).~%"
              base-fp fingerprint)
      (return-from compare-and-gate t)))
  (let ((map (baseline-entry-map baseline))
        (regressed nil))
    (format t "~&~%~A~%" (make-string 92 :initial-element #\=))
    (format t "~30A ~10A ~12A ~12A ~9A ~7A ~A~%"
            "entry" "unit" "base-median" "median" "delta%" "band%" "verdict")
    (format t "~A~%" (make-string 92 :initial-element #\-))
    (dolist (e entries)
      (let* ((name (getf e :name))
             (cur (getf e :median))
             (be (gethash name map)))
        (cond
          ((null be)
           (format t "~30A ~10A ~12A ~12,4F ~9A ~7A ~A~%"
                   name (getf e :unit) "(new)" cur "--" "--" "NEW"))
          ;; Budget-gated entries (e.g. telemetry) are governed by the
          ;; Constraint-4 hard budget in `budget-violations', not by the
          ;; median-band comparison: at sub-ns/op the band gate is
          ;; non-reproducible.  Print the delta for trend, never FAIL on it.
          ((budget-gated-p name)
           (let* ((base (gethash "median" be))
                  (delta (if (zerop base) 0d0 (/ (- cur base) base))))
             (format t "~30A ~10A ~12,4F ~12,4F ~8,2F% ~7A ~A~%"
                     name (getf e :unit) base cur
                     (* delta 100d0) "budget" "TREND")))
          (t
           (let* ((base (gethash "median" be))
                  (band (or (gethash "band" be) 0.05d0))
                  (delta (if (zerop base) 0d0 (/ (- cur base) base)))
                  (bad (> cur (* base (+ 1d0 band)))))
             (when bad (setf regressed t))
             (format t "~30A ~10A ~12,4F ~12,4F ~8,2F% ~6,2F% ~A~%"
                     name (getf e :unit) base cur
                     (* delta 100d0) (* band 100d0)
                     (if bad "FAIL" "OK")))))))
    (format t "~A~%" (make-string 92 :initial-element #\=))
    regressed))

;;;; ------------------------------------------------------------------
;;;; Rebaseline
;;;; ------------------------------------------------------------------

(defparameter +bench-band-floor+ 0.20d0
  "Minimum per-entry noise band.  SPEC-PERF PF-3 sets a 5% floor; we raise it to
20% and record the deviation in bench/README.md.  Two effects push real
variance past 5%: (1) the five suite runs that measure a band execute in one
process, so they share its CPU-frequency/thermal state and underestimate the
cross-process variance the gate (a fresh process) sees; (2) the pre-commit
machine is a shared workstation that runs concurrent CPU-heavy work (the
developer's own editor sessions, other agents), so a bench invocation that
collides with a busy period reads a whole entry's window slow.  Interleaving
(see `run-suite') and median-of-nine reject sub-second transients, but a
sustained busy period still lifts the consing-heavy :paranoid entries ~15-17%
between processes.  20% covers the observed jitter and still sits far below the
>1.5x (50%) hot-path regression SPEC-VK VK-4 treats as a blocker, so the gate
stays meaningful.  A quiet, CPU-pinned machine would justify a much tighter
floor via a per-machine rebaseline (Constraint 5).")

(defun aggregate-baseline (runs)
  "Fold RUNS (a list of >=1 suite results, each a list of entry plists keyed by
position) into baseline entries carrying a noise band.  The band is the spread
of the per-run medians as a fraction of the aggregate median, floored at
+bench-band-floor+."
  (loop :with count := (length (first runs))
        :for i :from 0 :below count
        :for entries := (mapcar (lambda (r) (nth i r)) runs)
        :for medians := (mapcar (lambda (e) (getf e :median)) entries)
        :for agg-median := (sorted-stat medians 0.50)
        :for spread := (if (or (null (cdr medians)) (zerop agg-median))
                           0d0
                           (/ (- (reduce #'max medians) (reduce #'min medians))
                              agg-median))
        :collect (let ((template (first entries)))
                   (list :name (getf template :name)
                         :unit (getf template :unit)
                         :min (reduce #'min (mapcar (lambda (e) (getf e :min)) entries))
                         :median agg-median
                         :p90 (reduce #'max (mapcar (lambda (e) (getf e :p90)) entries))
                         :consed-per-op (getf template :consed-per-op)
                         :n (getf template :n)
                         :band (max +bench-band-floor+ spread)))))

;;;; ------------------------------------------------------------------
;;;; Main
;;;; ------------------------------------------------------------------

(defun bench-commit ()
  (or (ignore-errors (lem-core:lem-git-revision)) "unknown"))

(defun baseline-path (baselines-dir slug tier)
  (merge-pathnames (format nil "~A-~A.json" slug tier)
                   (uiop:ensure-directory-pathname baselines-dir)))

(defun results-path (results-dir slug tier timestamp)
  (merge-pathnames (format nil "~A-~A-~A.json" slug tier timestamp)
                   (uiop:ensure-directory-pathname results-dir)))

(defun bench-main ()
  (let* ((mode (or (bench-getenv "LEM_BENCH_MODE") "measure"))
         (tier (or (bench-getenv "LEM_BENCH_TIER") "t1"))
         (fingerprint (or (bench-getenv "LEM_BENCH_FINGERPRINT") "unknown"))
         (slug (or (bench-getenv "LEM_BENCH_FP_SLUG") "unknown"))
         (timestamp (or (bench-getenv "LEM_BENCH_TIMESTAMP") "00000000000000"))
         (results-dir (or (bench-getenv "LEM_BENCH_RESULTS_DIR") "bench/results"))
         (baselines-dir (or (bench-getenv "LEM_BENCH_BASELINES_DIR") "bench/baselines"))
         (commit (bench-commit)))
    (cond
      ((string= mode "rebaseline")
       (format t "~&Rebaselining ~A (5 in-process suite runs)...~%" tier)
       (let* ((runs (loop :repeat 5 :collect (run-suite)))
              (final (car (last runs)))
              (violations (budget-violations final)))
         (when violations
           (format t "~&BUDGET VIOLATION -- refusing to write baseline:~%")
           (dolist (v violations) (format t "  - ~A~%" v))
           (uiop:quit 1))
         (let* ((baseline-entries (aggregate-baseline runs))
                (path (baseline-path baselines-dir slug tier)))
           (ensure-directories-exist path)
           (write-results-json path fingerprint tier commit timestamp
                               baseline-entries :band-p t)
           (dolist (e baseline-entries)
             (format t "  ~30A median=~,4F ~A  band=~,1F%  consed=~D B/op~%"
                     (getf e :name) (getf e :median) (getf e :unit)
                     (* 100d0 (getf e :band)) (getf e :consed-per-op)))
           (format t "~&Baseline written: ~A~%" path)
           (uiop:quit 0))))
      (t
       (let* ((entries (run-suite))
              (results (results-path results-dir slug tier timestamp))
              (violations (budget-violations entries)))
         (ensure-directories-exist results)
         (write-results-json results fingerprint tier commit timestamp entries)
         (format t "~&Results written: ~A~%" results)
         (when violations
           (format t "~&BUDGET VIOLATION (Constraint 4):~%")
           (dolist (v violations) (format t "  - ~A~%" v)))
         (let* ((bpath (baseline-path baselines-dir slug tier))
                (baseline (read-baseline bpath)))
           (unless baseline
             (format t "~&No baseline at ~A -- run: scripts/run-bench.sh --rebaseline ~A~%"
                     bpath tier)
             (uiop:quit (if violations 1 2)))
           (let ((regressed (compare-and-gate entries baseline fingerprint)))
             (cond
               ((or regressed violations)
                (format t "~&GATE: FAIL~%")
                (uiop:quit 1))
               (t
                (format t "~&GATE: PASS~%")
                (uiop:quit 0))))))))))

(handler-case
    (progn
      (bench-load-corpora)
      (bench-load-entry-files)
      (bench-main))
  (error (c)
    (format t "~&bench driver error: ~A: ~A~%" (type-of c) c)
    (uiop:quit 1)))
