;;;; run-t2.lisp -- T2 macro session-replay driver (SPEC-PERF PF-5 / PF-6).
;;;;
;;;; Loaded after `(ql:quickload :lem/core)' by `scripts/run-bench.sh'.  Where
;;;; the T1 driver (run-t1.lisp) measures per-primitive us/op, T2 replays whole
;;;; scripted editing sessions against the recording fake-interface (VK-12) at a
;;;; fixed 200x50 frame and reports, per workload: wall time, bytes consed, GC
;;;; count, GC pause total, and frames rendered.  It reuses the P1 harness
;;;; PATTERNS (a self-registering entry registry, `sorted-stat', the PF-3 JSON
;;;; schema, the 20% noise-band gate) adapted to the multi-metric workload case.
;;;;
;;;; The workload files live one-per-file under `scripts/bench/t2/' (NOT beside
;;;; this driver, so the T1 driver's sibling-*.lisp discovery never loads them);
;;;; each registers itself via `register-t2-workload' at load time.  Corpora come
;;;; from `bench/corpora/generate.lisp' (the pinned lisp-500k and the committed
;;;; mixed-10m generator).
;;;;
;;;; Environment (shared with run-t1.lisp; see run-bench.sh):
;;;;   LEM_BENCH_MODE "measure"|"rebaseline", LEM_BENCH_TIER "t2",
;;;;   LEM_BENCH_FINGERPRINT / _FP_SLUG / _TIMESTAMP / _RESULTS_DIR /
;;;;   _BASELINES_DIR, and the optional LEM_BENCH_ONLY entry filter.
;;;;
;;;; Measurement (per the task spec): for each workload, ONE warm-up execution
;;;; (discarded) then the MEDIAN of THREE full workload executions, with a full
;;;; `gc :full' before every execution (warm-up and timed).  Unlike T1, T2 does
;;;; NOT suppress GC in the timed window -- GC count and pause total ARE reported
;;;; metrics of the realistic session, so the natural GC behaviour is measured.

(in-package :cl-user)

(ql:quickload :lem-fake-interface :silent t)

;;;; ------------------------------------------------------------------
;;;; Environment helpers (mirrors run-t1.lisp)
;;;; ------------------------------------------------------------------

(defun bench-getenv (name)
  (let ((v (uiop:getenv name)))
    (if (and v (plusp (length v))) v nil)))

(defparameter *bench-only*
  (let ((v (bench-getenv "LEM_BENCH_ONLY")))
    (and v (loop :for start := 0 :then (1+ pos)
                 :for pos := (position #\, v :start start)
                 :collect (string-trim " " (subseq v start pos))
                 :while pos)))
  "When non-nil, the list of workload names to run (others are skipped).")

;;;; ------------------------------------------------------------------
;;;; Fixed 200x50 recording interface + frame counter (PF-5)
;;;; ------------------------------------------------------------------
;;;;
;;;; The base recording-fake-interface defaults to an 80x24 display; the T2
;;;; frame is fixed at 200x50 (SPEC-PERF PF-5), so a subclass overrides the two
;;;; display-size slot initforms.  The interface is installed as the process
;;;; implementation once, exactly as `invoke-frontend' would for a real
;;;; frontend, and `setup-first-frame' establishes the current 200x50 window --
;;;; the same setup the VK-12 screen-projection tests use, so the workloads
;;;; drive real commands (next-page, scroll-down, forward-char, ...) against a
;;;; genuine current window.

(defclass bench-t2-interface (lem-fake-interface:recording-fake-interface)
  ((lem-fake-interface::display-width :initform 200)
   (lem-fake-interface::display-height :initform 50))
  (:default-initargs :name :fake-t2))

(defvar *bench-frames* 0
  "Frame counter: incremented once per completed frame flush.  `redraw-display'
ends every pass with `lem-if:update-display', so this `:after' method is the
recording fake-interface's frame counter (SPEC-PERF PF-5 `frames rendered').")

(defmethod lem-if:update-display :after ((impl bench-t2-interface))
  (incf *bench-frames*))

(setf lem-core::*implementation* (make-instance 'bench-t2-interface))
(lem-core:setup-first-frame)

(defun bench-t2-render ()
  "Force a full redisplay of the current window (every op is a from-scratch
recompute, not a display-cache hit) and count the frame.  This is the workloads'
single render primitive; `force' is honoured because the fake interface's
`no-force-needed-p' is NIL."
  (lem:redraw-display :force t))

;;;; ------------------------------------------------------------------
;;;; Workload registry
;;;; ------------------------------------------------------------------

(defstruct t2-workload
  "One registered T2 workload.  SETUP is a thunk of no args, run ONCE, that
builds the (expensive) fixture and returns an opaque STATE.  RUN is a function
of that STATE performing one full scripted session; it must be replayable --
idempotent or net-zero -- so every execution starts from an identical state
(it resets the cursor / buffer at entry).  RUN forces redisplay per rendered
step via `bench-t2-render'."
  (name "" :type string)
  (setup (lambda () nil) :type function)
  (run (lambda (state) (declare (ignore state))) :type function))

(defvar *t2-workloads* '()
  "Registered workloads in registration order.")

(defun register-t2-workload (&key name setup run)
  "Register (or, by NAME, replace) a T2 workload.  Called from the workload
files at load time; replacing keeps the original position for stable ordering."
  (let ((wl (make-t2-workload :name name :setup setup :run run))
        (existing (find name *t2-workloads* :key #'t2-workload-name :test #'string=)))
    (if existing
        (setf *t2-workloads* (substitute wl existing *t2-workloads*))
        (setf *t2-workloads* (append *t2-workloads* (list wl))))
    wl))

(defun t2-workloads ()
  "The workloads to run, honouring LEM_BENCH_ONLY."
  (if *bench-only*
      (remove-if-not (lambda (w) (member (t2-workload-name w) *bench-only* :test #'string=))
                     *t2-workloads*)
      *t2-workloads*))

;;;; ------------------------------------------------------------------
;;;; Discovery / loading of workload files and corpora
;;;; ------------------------------------------------------------------

(defparameter *bench-source-dir*
  (uiop:pathname-directory-pathname (or *load-truename* *default-pathname-defaults*))
  "Directory holding this driver (scripts/bench/).")

(defun bench-load-corpora ()
  "Load the corpus generator and eagerly ensure every corpus (so a broken
generator fails loudly).  Reached via `find-symbol' -- the generator is loaded
at runtime, avoiding a compile-time forward reference.  The generator also
defines `bench-repo-root', which the workload files use after this load."
  (let* ((root (uiop:pathname-parent-directory-pathname
                (uiop:pathname-parent-directory-pathname *bench-source-dir*)))
         (gen (merge-pathnames "bench/corpora/generate.lisp" root)))
    (load gen)
    (funcall (or (find-symbol "BENCH-ENSURE-ALL-CORPORA" :cl-user)
                 (error "corpus generator did not define bench-ensure-all-corpora")))))

(defun bench-load-workload-files ()
  "Load every `scripts/bench/t2/*.lisp' workload file in sorted order (stable
registration order)."
  (dolist (path (sort (directory (merge-pathnames "t2/*.lisp" *bench-source-dir*))
                      #'string< :key #'namestring))
    (load path)))

;;;; ------------------------------------------------------------------
;;;; Measurement primitives
;;;; ------------------------------------------------------------------

(defun sorted-stat (samples fraction)
  "The FRACTION percentile of SAMPLES (a non-empty list) by nearest-rank."
  (let* ((sorted (sort (copy-list samples) #'<))
         (n (length sorted))
         (idx (min (1- n) (max 0 (1- (ceiling (* fraction n)))))))
    (nth idx sorted)))

(defun median (samples)
  (sorted-stat samples 0.50))

(defparameter +t2-timed-reps+ 3
  "Timed executions per workload per suite run (SPEC task: median of three).")

(defun t2-measure-once (workload state)
  "Run WORKLOAD once on STATE after a full GC and return a metrics plist:
wall-ms, consed (bytes), gc-count, gc-pause-ms, frames.  GC count is captured
with a transient `*after-gc-hooks*' counter; pause total from the
`sb-ext:*gc-run-time*' delta (internal-time-units = microseconds on SBCL)."
  (sb-ext:gc :full t)
  (let ((gc-count 0))
    (flet ((count-gc () (incf gc-count)))
      (let ((hook #'count-gc))
        (push hook sb-ext:*after-gc-hooks*)
        (unwind-protect
             (let ((frames0 *bench-frames*)
                   (consed0 (sb-ext:get-bytes-consed))
                   (gc-us0 sb-ext:*gc-run-time*)
                   (t0 (get-internal-real-time)))
               ;; Fresh command-flag context per execution.  `continue-flag'
               ;; (used by next-line/scroll) reads the dynamic `*last-flags*',
               ;; which the real command loop rebinds per keystroke; driving
               ;; commands as plain calls would otherwise leak flags across
               ;; workloads (a stale :next-line makes scroll-down skip
               ;; initialising cursor-saved-column and pass NIL to
               ;; move-to-column).  Binding both fresh mirrors one command-loop
               ;; iteration so the first vertical move initialises the goal
               ;; column, exactly as it does in the editor.
               (let ((lem-core::*last-flags* nil)
                     (lem-core::*curr-flags* nil))
                 (funcall (t2-workload-run workload) state))
               (let ((elapsed (- (get-internal-real-time) t0)))
                 (list :wall-ms (/ (* (float elapsed 1d0) 1000d0)
                                   (float internal-time-units-per-second 1d0))
                       :consed (- (sb-ext:get-bytes-consed) consed0)
                       :gc-count gc-count
                       :gc-pause-ms (/ (float (- sb-ext:*gc-run-time* gc-us0) 1d0) 1000d0)
                       :frames (- *bench-frames* frames0))))
          (setf sb-ext:*after-gc-hooks* (remove hook sb-ext:*after-gc-hooks*)))))))

(defun t2-aggregate-samples (wl samples)
  "Fold a workload WL's timed SAMPLES (metrics plists) into a result plist
(PF-3 schema + additive gc/frame metrics).  Wall-ms carries min/median/p90;
consed/gc/frames carry the median across the reps."
  (let ((walls (mapcar (lambda (s) (getf s :wall-ms)) samples)))
    (list :name (t2-workload-name wl)
          :unit "ms/workload"
          :min (reduce #'min walls)
          :median (median walls)
          :p90 (sorted-stat walls 0.90)
          :consed-per-op (round (median (mapcar (lambda (s) (getf s :consed)) samples)))
          :gc-count (round (median (mapcar (lambda (s) (getf s :gc-count)) samples)))
          :gc-pause-ms (median (mapcar (lambda (s) (getf s :gc-pause-ms)) samples))
          :frames (round (median (mapcar (lambda (s) (getf s :frames)) samples)))
          :n 1)))

(defun t2-run-one-suite ()
  "One suite pass over every workload.  Fixtures are built once (untimed); then
ONE warm-up pass (all workloads, discarded) and +t2-timed-reps+ timed passes.
The timed passes are INTERLEAVED -- round-robin across workloads, not all of one
workload back-to-back -- so a transient machine-load spell (this is a shared
workstation) lands on at most one rep per workload instead of clustering on two
of a single workload's three consecutive reps and skewing its median.  This is
the T1 driver's interleaving hygiene (bench/README.md) applied to the T2 median
of three: it keeps each suite median robust, so the rebaseline band settles near
the 20% floor instead of inflating on a lone outlier.  A full `gc :full'
precedes every execution (inside `t2-measure-once')."
  (let* ((wls (t2-workloads))
         (states (mapcar (lambda (w) (funcall (t2-workload-setup w))) wls))
         (samples (make-hash-table :test 'eq)))
    (loop :for w :in wls :for s :in states       ; warm-up pass, discarded
          :do (t2-measure-once w s))
    (dotimes (rep +t2-timed-reps+)                ; interleaved timed passes
      (loop :for w :in wls :for s :in states
            :do (push (t2-measure-once w s) (gethash w samples))))
    (mapcar (lambda (w) (t2-aggregate-samples w (gethash w samples))) wls)))

;;;; ------------------------------------------------------------------
;;;; JSON I/O (PF-3 schema + additive T2 metrics)
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
    ;; Additive T2 metrics (SPEC-PERF PF-5): reported alongside the gated wall
    ;; time.  The gate is on wall-ms; these are recorded for trend/analysis.
    (yason:encode-object-element "gc-count" (getf e :gc-count))
    (yason:encode-object-element "gc-pause-ms" (getf e :gc-pause-ms))
    (yason:encode-object-element "frames" (getf e :frames))
    (when band-p
      (yason:encode-object-element "band" (getf e :band)))))

(defun write-results-json (path fingerprint tier commit timestamp entries &key band-p)
  (with-open-file (out path :direction :output
                            :if-exists :supersede :if-does-not-exist :create)
    (yason:with-output (out :indent t)
      (yason:with-object ()
        (yason:encode-object-element "fingerprint" fingerprint)
        (yason:encode-object-element "tier" tier)
        (yason:encode-object-element "commit" (or commit "unknown"))
        (yason:encode-object-element "timestamp" timestamp)
        (yason:with-object-element ("entries")
          (yason:with-array ()
            (dolist (e entries) (encode-entry e :band-p band-p))))))))

(defun read-baseline (path)
  (with-open-file (in path :if-does-not-exist nil)
    (and in (yason:parse in :object-as :hash-table))))

;;;; ------------------------------------------------------------------
;;;; Comparison / gating (wall-ms median vs baseline, 20% band floor)
;;;; ------------------------------------------------------------------

(defparameter +bench-band-floor+ 0.20d0
  "Minimum per-workload noise band, matching the T1 driver's floor (SPEC-PERF
PF-3 sets 5%; the P1 deviation raises it to 20% for this shared workstation --
see bench/README.md).  T2 sessions are longer and consing-heavy, so cross-run
wall-time swing is at least as wide as T1's; 20% covers it and stays well below
a >1.5x regression.")

(defun baseline-entry-map (baseline)
  (let ((map (make-hash-table :test 'equal)))
    (dolist (be (gethash "entries" baseline) map)
      (setf (gethash (gethash "name" be) map) be))))

(defun compare-and-gate (entries baseline fingerprint)
  "Print a delta table comparing ENTRIES' wall-ms medians against BASELINE and
return T if any workload regressed beyond its noise band (T2 is a gated tier)."
  (let ((base-fp (gethash "fingerprint" baseline)))
    (unless (equal base-fp fingerprint)
      (format t "~&REFUSING TO GATE: baseline fingerprint~%  [~A]~%~
                 does not match this machine~%  [~A]~%~
                 (Constraint 5: comparisons only run on a matching fingerprint).~%"
              base-fp fingerprint)
      (return-from compare-and-gate t)))
  (let ((map (baseline-entry-map baseline))
        (regressed nil))
    (format t "~&~%~A~%" (make-string 104 :initial-element #\=))
    (format t "~20A ~12A ~12A ~12A ~9A ~7A ~8A ~7A ~A~%"
            "workload" "unit" "base-med" "median" "delta%" "band%" "frames" "gc" "verdict")
    (format t "~A~%" (make-string 104 :initial-element #\-))
    (dolist (e entries)
      (let* ((name (getf e :name))
             (cur (getf e :median))
             (be (gethash name map)))
        (cond
          ((null be)
           (format t "~20A ~12A ~12A ~12,1F ~9A ~7A ~8D ~7D ~A~%"
                   name (getf e :unit) "(new)" cur "--" "--"
                   (getf e :frames) (getf e :gc-count) "NEW"))
          (t
           (let* ((base (gethash "median" be))
                  (band (or (gethash "band" be) +bench-band-floor+))
                  (delta (if (zerop base) 0d0 (/ (- cur base) base)))
                  (bad (> cur (* base (+ 1d0 band)))))
             (when bad (setf regressed t))
             (format t "~20A ~12A ~12,1F ~12,1F ~8,2F% ~6,2F% ~8D ~7D ~A~%"
                     name (getf e :unit) base cur
                     (* delta 100d0) (* band 100d0)
                     (getf e :frames) (getf e :gc-count)
                     (if bad "FAIL" "OK")))))))
    (format t "~A~%" (make-string 104 :initial-element #\=))
    regressed))

;;;; ------------------------------------------------------------------
;;;; Rebaseline (5 suite runs; band = spread of medians, floored)
;;;; ------------------------------------------------------------------

(defun aggregate-baseline (runs)
  "Fold RUNS (>=1 suite results, entry plists keyed by position) into baseline
entries carrying a noise band = spread of the per-run wall-ms medians as a
fraction of the aggregate median, floored at +bench-band-floor+."
  (loop :with count := (length (first runs))
        :for i :from 0 :below count
        :for entries := (mapcar (lambda (r) (nth i r)) runs)
        :for medians := (mapcar (lambda (e) (getf e :median)) entries)
        :for agg-median := (median medians)
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
                         :gc-count (getf template :gc-count)
                         :gc-pause-ms (getf template :gc-pause-ms)
                         :frames (getf template :frames)
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

(defparameter +t2-rebaseline-suites+ 5
  "Suite runs folded into a rebaseline band (SPEC-PERF Constraint 5: >=5).")

(defun bench-main ()
  (let* ((mode (or (bench-getenv "LEM_BENCH_MODE") "measure"))
         (tier (or (bench-getenv "LEM_BENCH_TIER") "t2"))
         (fingerprint (or (bench-getenv "LEM_BENCH_FINGERPRINT") "unknown"))
         (slug (or (bench-getenv "LEM_BENCH_FP_SLUG") "unknown"))
         (timestamp (or (bench-getenv "LEM_BENCH_TIMESTAMP") "00000000000000"))
         (results-dir (or (bench-getenv "LEM_BENCH_RESULTS_DIR") "bench/results"))
         (baselines-dir (or (bench-getenv "LEM_BENCH_BASELINES_DIR") "bench/baselines"))
         (commit (bench-commit)))
    (cond
      ((string= mode "rebaseline")
       (format t "~&Rebaselining ~A (~D suite runs)...~%" tier +t2-rebaseline-suites+)
       (let* ((runs (loop :repeat +t2-rebaseline-suites+ :collect (t2-run-one-suite)))
              (baseline-entries (aggregate-baseline runs))
              (path (baseline-path baselines-dir slug tier)))
         (ensure-directories-exist path)
         (write-results-json path fingerprint tier commit timestamp baseline-entries :band-p t)
         (dolist (e baseline-entries)
           (format t "  ~20A median=~,1F ~A  band=~,1F%  consed=~D B  gc=~D  frames=~D~%"
                   (getf e :name) (getf e :median) (getf e :unit)
                   (* 100d0 (getf e :band)) (getf e :consed-per-op)
                   (getf e :gc-count) (getf e :frames)))
         (format t "~&Baseline written: ~A~%" path)
         (uiop:quit 0)))
      (t
       (let* ((entries (t2-run-one-suite))
              (results (results-path results-dir slug tier timestamp)))
         (ensure-directories-exist results)
         (write-results-json results fingerprint tier commit timestamp entries)
         (format t "~&Results written: ~A~%" results)
         (let* ((bpath (baseline-path baselines-dir slug tier))
                (baseline (read-baseline bpath)))
           (unless baseline
             (format t "~&No baseline at ~A -- run: scripts/run-bench.sh --rebaseline ~A~%"
                     bpath tier)
             (uiop:quit 2))
           (let ((regressed (compare-and-gate entries baseline fingerprint)))
             (cond
               (regressed (format t "~&GATE: FAIL~%") (uiop:quit 1))
               (t (format t "~&GATE: PASS~%") (uiop:quit 0))))))))))

(handler-case
    (progn
      (bench-load-corpora)
      (bench-load-workload-files)
      (bench-main))
  (error (c)
    (format t "~&bench driver error: ~A: ~A~%" (type-of c) c)
    (uiop:quit 1)))
