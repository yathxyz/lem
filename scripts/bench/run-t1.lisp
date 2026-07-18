;;;; run-t1.lisp -- T1 micro-benchmark driver (SPEC-PERF PF-3).
;;;;
;;;; Loaded after `(ql:quickload :lem/core)` by `scripts/run-bench.sh`.  The
;;;; runner passes configuration through the environment:
;;;;
;;;;   LEM_BENCH_MODE          "measure" | "rebaseline"
;;;;   LEM_BENCH_TIER          "t1"
;;;;   LEM_BENCH_FINGERPRINT   full machine/CPU fingerprint string
;;;;   LEM_BENCH_TIMESTAMP     YYYYMMDDHHMMSS (shared with the results filename)
;;;;   LEM_BENCH_FP_SLUG       filesystem-safe fingerprint slug
;;;;   LEM_BENCH_RESULTS_DIR   directory for result JSON files
;;;;   LEM_BENCH_BASELINES_DIR directory holding the committed baselines
;;;;   LEM_BENCH_INJECT_SLEEP_US  optional: busy-wait this many us per op
;;;;                              (self-test hook: injects a synthetic regression)
;;;;
;;;; Measurement obeys SPEC-PERF Constraint 5: `gc :full' before each timed
;;;; section, one warm-up repetition discarded, median of five in-process
;;;; repetitions, reporting min/median/p90 plus bytes-consed/op.
;;;;
;;;; The single P0 entry is `telemetry': the PF-1 record path.  It permanently
;;;; enforces the Constraint-4 budget (< 1 us/op and 0 bytes consed/op); a
;;;; violation fails the run regardless of the baseline comparison.

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
  "When non-nil, each measured op busy-waits this many microseconds, standing
in for a real slowdown so the gate machinery can be self-tested.")

;;;; ------------------------------------------------------------------
;;;; Measurement primitives
;;;; ------------------------------------------------------------------

(defun bench-busy-us (us)
  "Busy-wait for approximately US microseconds on the process-wide monotonic
clock.  Used only by the self-test injection path."
  (declare (type fixnum us))
  (let ((end (+ (get-internal-real-time)
                (truncate (* us internal-time-units-per-second) 1000000))))
    (loop :while (< (get-internal-real-time) end))))

(defun time-us-per-op (inner thunk)
  "Run THUNK over INNER iterations after a full GC and return microseconds per
op as a double-float."
  (sb-ext:gc :full t)
  (let ((t0 (get-internal-real-time)))
    (funcall thunk inner)
    (let ((elapsed (- (get-internal-real-time) t0)))
      (/ (* (float elapsed 1d0) 1000000d0)
         (float internal-time-units-per-second 1d0)
         (float inner 1d0)))))

(defun consed-per-op (inner thunk)
  "Bytes consed per op while running THUNK over INNER iterations.  Deliberately
does NOT force a GC first (post-GC TLAB accounting would add a fixed offset that
hides the true per-op figure, per the PF-1 test's measure-consed)."
  (let ((before (sb-ext:get-bytes-consed)))
    (funcall thunk inner)
    (floor (- (sb-ext:get-bytes-consed) before) inner)))

(defun sorted-stat (samples fraction)
  "The FRACTION percentile of SAMPLES (a non-empty list) by nearest-rank."
  (let* ((sorted (sort (copy-list samples) #'<))
         (n (length sorted))
         (idx (min (1- n) (max 0 (1- (ceiling (* fraction n)))))))
    (nth idx sorted)))

(defun run-entry (name unit inner make-thunk)
  "Measure one entry.  MAKE-THUNK returns a function of (count) that performs
COUNT ops.  Returns a result plist matching the PF-3 schema."
  (let ((thunk (funcall make-thunk)))
    (time-us-per-op inner thunk)            ; warm-up, discarded
    (let* ((samples (loop :repeat 5 :collect (time-us-per-op inner thunk)))
           (consed (consed-per-op inner thunk)))
      (list :name name
            :unit unit
            :min (reduce #'min samples)
            :median (sorted-stat samples 0.50)
            :p90 (sorted-stat samples 0.90)
            :consed-per-op consed
            :n inner))))

;;;; ------------------------------------------------------------------
;;;; Entries
;;;; ------------------------------------------------------------------

(defun telemetry-thunk ()
  "A closure of (count) driving the PF-1 record path COUNT times.  The record
call is `lem/metrics:histogram-record', which is declaimed inline, so this is
the same code the running editor executes on the hot path."
  (let ((h (lem/metrics:make-histogram))
        (inject *inject-sleep-us*))
    (if inject
        (lambda (count)
          (declare (type fixnum count inject) (optimize (speed 3) (safety 1)))
          (dotimes (i count)
            (lem/metrics:histogram-record h 12345)
            (bench-busy-us inject)))
        (lambda (count)
          (declare (type fixnum count) (optimize (speed 3) (safety 1)))
          (dotimes (i count)
            (lem/metrics:histogram-record h 12345))))))

(defun run-suite ()
  "Run every T1 entry once and return the list of result plists."
  (let ((inner (if *inject-sleep-us* 2000 1000000)))
    (list (run-entry "telemetry" "us/op" inner #'telemetry-thunk))))

;;;; ------------------------------------------------------------------
;;;; Budgets (Constraint 4, permanent)
;;;; ------------------------------------------------------------------

(defun budget-violations (entries)
  "Return a list of human-readable budget-violation strings for ENTRIES.
The `telemetry' entry must stay under 1 us/op and cons nothing."
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
    (format t "~&~%~A~%" (make-string 78 :initial-element #\=))
    (format t "~24A ~10A ~12A ~12A ~9A ~7A ~A~%"
            "entry" "unit" "base-median" "median" "delta%" "band%" "verdict")
    (format t "~A~%" (make-string 78 :initial-element #\-))
    (dolist (e entries)
      (let* ((name (getf e :name))
             (cur (getf e :median))
             (be (gethash name map)))
        (if (null be)
            (format t "~24A ~10A ~12A ~12,4F ~9A ~7A ~A~%"
                    name (getf e :unit) "(new)" cur "--" "--" "NEW")
            (let* ((base (gethash "median" be))
                   (band (or (gethash "band" be) 0.05d0))
                   (delta (if (zerop base) 0d0 (/ (- cur base) base)))
                   (bad (> cur (* base (+ 1d0 band)))))
              (when bad (setf regressed t))
              (format t "~24A ~10A ~12,4F ~12,4F ~8,2F% ~6,2F% ~A~%"
                      name (getf e :unit) base cur
                      (* delta 100d0) (* band 100d0)
                      (if bad "FAIL" "OK"))))))
    (format t "~A~%" (make-string 78 :initial-element #\=))
    regressed))

;;;; ------------------------------------------------------------------
;;;; Rebaseline
;;;; ------------------------------------------------------------------

(defun aggregate-baseline (runs)
  "Fold RUNS (a list of >=1 suite results, each a list of entry plists keyed by
position) into baseline entries carrying a noise band.  The band is the spread
of the per-run medians as a fraction of the aggregate median, floored at 5%
(SPEC-PERF PF-3)."
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
                         :band (max 0.05d0 spread)))))

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
             (format t "  ~A: median=~,4F ~A  band=~,1F%  consed=~D B/op~%"
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

(handler-case (bench-main)
  (error (c)
    (format t "~&bench driver error: ~A: ~A~%" (type-of c) c)
    (uiop:quit 1)))
