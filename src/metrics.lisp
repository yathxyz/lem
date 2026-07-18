(defpackage :lem/metrics
  (:use :cl :lem-core)
  (:documentation
   "T0 field telemetry core (SPEC-PERF PF-1).

Always-on, allocation-free-on-the-hot-path instrumentation for the
running editor: log2 latency histograms, a per-command dispatch table, a
GC pause log, and a heap/RSS sample ring.  Recording is gated by the
`record-metrics' editor variable (default on).  Data is summarised by
`metrics-report' and serialised to JSON by `metrics-dump'.

Thread-safety is by partition-by-writer: each writer thread increments
its own private set of histograms with no locks and no atomics; the
reader (report/dump) merges partitions.  Reads race benignly against
in-flight increments, which is acceptable for statistical counters.

PF-2 threads the input->paint pipeline timestamps through the exported
`record-*' entry points defined here; this file adds no pipeline
timestamps of its own.")
  (:export
   ;; recording gate
   :record-metrics
   ;; hot-path entry points (PF-2 calls these)
   :record-keystroke-latency
   :record-queue-wait
   :record-command-duration
   :record-redisplay-duration
   ;; lifecycle
   :start-metrics
   :stop-metrics
   ;; introspection / test surface
   :make-histogram
   :histogram-record
   :histogram-percentile
   :histogram-total-count
   :histogram-min
   :histogram-max
   :histogram-merge-into
   :current-partition
   :reset-metrics
   :metrics->hash-table
   :dump-metrics-to-file))
(in-package :lem/metrics)

;;;; ------------------------------------------------------------------
;;;; Parameters
;;;; ------------------------------------------------------------------

(defconstant +histogram-buckets+ 32
  "Number of log2 buckets per histogram.  Bucket k (k>=1) covers
microsecond values whose `integer-length' is k, i.e. [2^(k-1), 2^k-1];
bucket 0 holds the value 0.  32 buckets span 0 .. ~2^31 us (~35 min),
well past the 16 s ceiling in SPEC-PERF; out-of-range values clamp to
the top bucket.")

(defconstant +command-table-capacity+ 256
  "Maximum number of distinct command names tracked per partition before
further names fall into the shared overflow histogram.")

(defconstant +gc-ring-size+ 4096
  "Number of most-recent GCs retained in the GC ring buffer.")

(defconstant +heap-ring-size+ 8640
  "Number of heap/RSS samples retained (~24 h at one sample / 10 s).")

(defparameter *heap-sample-interval-seconds* 10
  "Idle-timer period for heap/RSS sampling.")

;;;; ------------------------------------------------------------------
;;;; State
;;;; ------------------------------------------------------------------

(defvar *metrics-recording-p* t
  "Fast boolean gate read on the hot path; kept in sync with the
`record-metrics' editor variable via its change hook.")

(defvar *partitions* '()
  "Association list mapping a writer thread to its `partition'.  Read
lock-free on the hot path; mutated only under `*partitions-lock*' when a
thread first records.  A single `setf' of the list head publishes a new
partition; readers observe either the old or the new head, both valid.")

(defvar *partitions-lock* (bt2:make-lock :name "lem-metrics partitions")
  "Guards partition *creation* only; increments never take it.")

(defvar *session-start-universal-time* nil
  "Universal time at which the current recording session began.")

(defvar *session-start-internal-time* nil
  "`get-internal-real-time' captured at session start, for uptime.")

(defvar *heap-timer* nil
  "The idle timer sampling heap/RSS, or NIL when not running.")

(defvar *gc-installed-p* nil
  "True once the after-GC hook has been installed (installed once).")

(defvar *last-gc-run-time* 0
  "`sb-ext:*gc-run-time*' at the previous GC, for pause deltas.")

;;;; ------------------------------------------------------------------
;;;; Editor variable
;;;; ------------------------------------------------------------------

(defun %set-recording-enabled (value)
  "Change hook for `record-metrics': mirror VALUE into the fast gate."
  (setf *metrics-recording-p* (and value t)))

(define-editor-variable record-metrics t
  "When non-nil (the default), the editor records T0 field telemetry
(latency histograms, GC log, heap samples).  Setting the global value to
nil turns all recording off with near-zero residual overhead."
  '%set-recording-enabled)

;;;; ------------------------------------------------------------------
;;;; Histogram (log2-bucketed, raw fixnum vectors, alloc-free record)
;;;; ------------------------------------------------------------------

(deftype count-vector () `(simple-array fixnum (,+histogram-buckets+)))

(defun %make-count-vector ()
  (make-array +histogram-buckets+ :element-type 'fixnum :initial-element 0))

(defstruct (histogram (:constructor make-histogram))
  "A log2-bucketed counter over non-negative microsecond values.  The
record path allocates nothing; percentiles are estimated from bucket
edges, so they carry the bounded error inherent to log2 bucketing."
  (counts (%make-count-vector) :type count-vector)
  (total-count 0 :type fixnum)
  ;; Sum of recorded values, for the mean.  Bounded by 2^62 us (~146k
  ;; years) on 64-bit SBCL, so it never leaves the fixnum range in
  ;; practice and the running total stays allocation-free.
  (sum 0 :type fixnum)
  (min most-positive-fixnum :type fixnum)
  (max 0 :type fixnum))

(declaim (inline histogram-bucket-index))
(defun histogram-bucket-index (value)
  "Return the log2 bucket index for the non-negative microsecond VALUE,
clamped into [0, +histogram-buckets+-1]."
  (declare (type fixnum value))
  (let ((i (integer-length value)))
    (declare (type (integer 0 63) i))
    (if (>= i +histogram-buckets+)
        (1- +histogram-buckets+)
        i)))

(declaim (inline histogram-record))
(defun histogram-record (histogram value)
  "Record microsecond VALUE into HISTOGRAM.  Allocation-free: this is the
hot-path primitive and consing here would be the observer effect the
telemetry is built to avoid (SPEC-PERF Constraint 4)."
  (declare (type histogram histogram)
           (type fixnum value)
           (optimize (speed 3) (safety 1)))
  (let ((v (if (< value 0) 0 value)))
    (declare (type fixnum v))
    (incf (aref (histogram-counts histogram) (histogram-bucket-index v)))
    (incf (histogram-total-count histogram))
    (incf (histogram-sum histogram) v)
    (when (< v (histogram-min histogram))
      (setf (histogram-min histogram) v))
    (when (> v (histogram-max histogram))
      (setf (histogram-max histogram) v))
    (values)))

(defun histogram-bucket-upper-edge (index)
  "Upper microsecond edge represented by bucket INDEX (a power of two)."
  (if (zerop index) 0 (ash 1 index)))

(defun histogram-percentile (histogram fraction)
  "Estimate the FRACTION (0..1) percentile of HISTOGRAM in microseconds,
returning the upper edge of the crossing bucket.  Returns 0 for an empty
histogram."
  (let ((total (histogram-total-count histogram)))
    (if (zerop total)
        0
        (let ((target (ceiling (* fraction total)))
              (cumulative 0)
              (counts (histogram-counts histogram)))
          (loop :for i :from 0 :below +histogram-buckets+
                :do (incf cumulative (aref counts i))
                    (when (>= cumulative target)
                      (return (histogram-bucket-upper-edge i)))
                :finally (return (histogram-max histogram)))))))

(defun histogram-mean (histogram)
  "Arithmetic mean of the recorded values, or 0 when empty."
  (let ((total (histogram-total-count histogram)))
    (if (zerop total) 0 (round (histogram-sum histogram) total))))

(defun histogram-merge-into (destination source)
  "Add every count of SOURCE into DESTINATION.  Used to aggregate
per-writer partitions for reporting; DESTINATION is a private
accumulator, never a live partition."
  (let ((dc (histogram-counts destination))
        (sc (histogram-counts source)))
    (loop :for i :from 0 :below +histogram-buckets+
          :do (incf (aref dc i) (aref sc i))))
  (incf (histogram-total-count destination) (histogram-total-count source))
  (incf (histogram-sum destination) (histogram-sum source))
  (when (< (histogram-min source) (histogram-min destination))
    (setf (histogram-min destination) (histogram-min source)))
  (when (> (histogram-max source) (histogram-max destination))
    (setf (histogram-max destination) (histogram-max source)))
  destination)

;;;; ------------------------------------------------------------------
;;;; Partition (one per writer thread)
;;;; ------------------------------------------------------------------

(defstruct (partition (:constructor %make-partition))
  "The private histogram set owned by a single writer thread."
  (thread nil)
  (keystroke (make-histogram) :type histogram)
  (queue-wait (make-histogram) :type histogram)
  (redisplay (make-histogram) :type histogram)
  ;; command name (symbol) -> histogram; owned by one thread, no lock.
  (command-table (make-hash-table :test 'eq :size +command-table-capacity+))
  (command-overflow (make-histogram) :type histogram))

(defun %create-partition (thread)
  "Create, register, and return the partition owned by THREAD.  Takes the
creation lock and double-checks so two first-touch racers agree."
  (bt2:with-lock-held (*partitions-lock*)
    (or (cdr (assoc thread *partitions*))
        (let ((partition (%make-partition :thread thread)))
          (setf *partitions* (acons thread partition *partitions*))
          partition))))

(declaim (inline current-partition))
(defun current-partition ()
  "Return the calling thread's partition, creating it on first touch.
The fast path is a lock-free `assoc' that conses nothing."
  (let ((thread sb-thread:*current-thread*))
    (or (cdr (assoc thread *partitions*))
        (%create-partition thread))))

(defun partition-command-histogram (partition name)
  "Return the histogram for command NAME in PARTITION, allocating a new
entry on first sight until the table is full, then folding further names
into the shared overflow histogram (SPEC-PERF: bounded table, overflow
bucket)."
  (let ((table (partition-command-table partition)))
    (or (gethash name table)
        (if (< (hash-table-count table) +command-table-capacity+)
            (setf (gethash name table) (make-histogram))
            (partition-command-overflow partition)))))

;;;; ------------------------------------------------------------------
;;;; Hot-path record entry points (PF-2 threads timestamps into these)
;;;; ------------------------------------------------------------------

(defun record-keystroke-latency (microseconds)
  "Record an input-event -> redisplay-complete latency of MICROSECONDS,
the keystroke-to-paint proxy.  No-op when recording is disabled."
  (declare (type fixnum microseconds))
  (when *metrics-recording-p*
    (histogram-record (partition-keystroke (current-partition)) microseconds)))

(defun record-queue-wait (microseconds)
  "Record an event queue wait (dequeue minus enqueue) of MICROSECONDS."
  (declare (type fixnum microseconds))
  (when *metrics-recording-p*
    (histogram-record (partition-queue-wait (current-partition)) microseconds)))

(defun record-command-duration (name microseconds)
  "Record a dispatch of command NAME (a symbol) taking MICROSECONDS."
  (declare (type fixnum microseconds))
  (when *metrics-recording-p*
    (let ((partition (current-partition)))
      (histogram-record (partition-command-histogram partition name)
                        microseconds))))

(defun record-redisplay-duration (microseconds)
  "Record a redisplay pass taking MICROSECONDS."
  (declare (type fixnum microseconds))
  (when *metrics-recording-p*
    (histogram-record (partition-redisplay (current-partition)) microseconds)))

;;;; ------------------------------------------------------------------
;;;; GC log (ring buffer + pause histogram) via *after-gc-hooks*
;;;; ------------------------------------------------------------------

(defstruct (gc-log (:constructor %make-gc-log))
  "Ring buffer of the last +gc-ring-size+ GCs plus a pause histogram.
Written only from `sb-ext:*after-gc-hooks*', which SBCL runs serially
(GC is stop-the-world), so no lock is needed against concurrent writers."
  (count 0 :type fixnum)
  (write-index 0 :type fixnum)
  (pause-us (make-array +gc-ring-size+ :element-type 'fixnum :initial-element 0)
   :type (simple-array fixnum (*)))
  (heap-after (make-array +gc-ring-size+ :element-type 'fixnum :initial-element 0)
   :type (simple-array fixnum (*)))
  (pause-histogram (make-histogram) :type histogram))

(defvar *gc-log* (%make-gc-log))

(defun metrics-after-gc ()
  "After-GC hook: append this GC's pause estimate and post-GC heap size
to the ring and pause histogram.  Allocation-free."
  (when *metrics-recording-p*
    (let* ((now sb-ext:*gc-run-time*)
           (pause (max 0 (- now *last-gc-run-time*)))
           (heap (sb-kernel:dynamic-usage))
           (log *gc-log*)
           (i (mod (gc-log-write-index log) +gc-ring-size+)))
      (declare (type fixnum pause heap i))
      (setf *last-gc-run-time* now)
      (setf (aref (gc-log-pause-us log) i) pause)
      (setf (aref (gc-log-heap-after log) i)
            (if (typep heap 'fixnum) heap most-positive-fixnum))
      (incf (gc-log-write-index log))
      (incf (gc-log-count log))
      (histogram-record (gc-log-pause-histogram log) pause))))

(defun install-gc-hook ()
  "Install the after-GC hook exactly once."
  (unless *gc-installed-p*
    (setf *last-gc-run-time* sb-ext:*gc-run-time*)
    (pushnew 'metrics-after-gc sb-ext:*after-gc-hooks*)
    (setf *gc-installed-p* t)))

;;;; ------------------------------------------------------------------
;;;; Heap / RSS sample ring (idle timer)
;;;; ------------------------------------------------------------------

(defstruct (heap-log (:constructor %make-heap-log))
  "Ring buffer of heap (`dynamic-usage') and RSS samples."
  (count 0 :type fixnum)
  (write-index 0 :type fixnum)
  (seconds (make-array +heap-ring-size+ :element-type 'fixnum :initial-element 0)
   :type (simple-array fixnum (*)))
  (dynamic-usage (make-array +heap-ring-size+ :element-type 'fixnum :initial-element 0)
   :type (simple-array fixnum (*)))
  (rss (make-array +heap-ring-size+ :element-type 'fixnum :initial-element 0)
   :type (simple-array fixnum (*))))

(defvar *heap-log* (%make-heap-log))

(defun read-vmrss-bytes ()
  "Return resident set size in bytes from /proc/self/status, or 0 when
unavailable (non-Linux, or the field is missing)."
  (handler-case
      (with-open-file (in "/proc/self/status" :if-does-not-exist nil)
        (if (null in)
            0
            (loop :for line := (read-line in nil nil)
                  :while line
                  :when (and (>= (length line) 6)
                             (string= "VmRSS:" line :end2 6))
                    :do (return
                          (* 1024
                             (or (parse-integer line
                                                :start 6
                                                :junk-allowed t)
                                 0)))
                  :finally (return 0))))
    (error () 0)))

(defun metrics-heap-sample ()
  "Idle-timer callback: append one heap/RSS sample to the ring."
  (when *metrics-recording-p*
    (let* ((log *heap-log*)
           (i (mod (heap-log-write-index log) +heap-ring-size+))
           (heap (sb-kernel:dynamic-usage))
           (uptime (floor (- (get-internal-real-time)
                             (or *session-start-internal-time*
                                 (get-internal-real-time)))
                          internal-time-units-per-second)))
      (setf (aref (heap-log-seconds log) i) uptime)
      (setf (aref (heap-log-dynamic-usage log) i)
            (if (typep heap 'fixnum) heap most-positive-fixnum))
      (setf (aref (heap-log-rss log) i) (read-vmrss-bytes))
      (incf (heap-log-write-index log))
      (incf (heap-log-count log)))))

;;;; ------------------------------------------------------------------
;;;; Aggregation (merge partitions for reading)
;;;; ------------------------------------------------------------------

(defstruct (snapshot (:constructor %make-snapshot))
  "A merged, read-only view over all partitions at a point in time."
  (keystroke (make-histogram) :type histogram)
  (queue-wait (make-histogram) :type histogram)
  (redisplay (make-histogram) :type histogram)
  (command-overflow (make-histogram) :type histogram)
  ;; name -> merged histogram
  (commands (make-hash-table :test 'eq)))

(defun aggregate-partitions ()
  "Merge every partition into a fresh `snapshot'.  Reads may race with
live increments; the resulting counts are statistically accurate."
  (let ((snapshot (%make-snapshot)))
    (dolist (entry *partitions* snapshot)
      (let ((partition (cdr entry)))
        (histogram-merge-into (snapshot-keystroke snapshot)
                              (partition-keystroke partition))
        (histogram-merge-into (snapshot-queue-wait snapshot)
                              (partition-queue-wait partition))
        (histogram-merge-into (snapshot-redisplay snapshot)
                              (partition-redisplay partition))
        (histogram-merge-into (snapshot-command-overflow snapshot)
                              (partition-command-overflow partition))
        (maphash (lambda (name histogram)
                   (let ((merged (or (gethash name (snapshot-commands snapshot))
                                     (setf (gethash name (snapshot-commands snapshot))
                                           (make-histogram)))))
                     (histogram-merge-into merged histogram)))
                 (partition-command-table partition))))))

(defun sorted-command-entries (snapshot)
  "Return (name . histogram) pairs from SNAPSHOT sorted by total recorded
time (sum) descending."
  (let ((entries '()))
    (maphash (lambda (name histogram) (push (cons name histogram) entries))
             (snapshot-commands snapshot))
    (sort entries #'> :key (lambda (e) (histogram-sum (cdr e))))))

;;;; ------------------------------------------------------------------
;;;; Serialisation (JSON)
;;;; ------------------------------------------------------------------

(defun universal-time->iso (universal-time)
  "Render UNIVERSAL-TIME as an ISO-8601 local timestamp."
  (multiple-value-bind (sec min hour day month year)
      (decode-universal-time universal-time)
    (format nil "~4,'0D-~2,'0D-~2,'0DT~2,'0D:~2,'0D:~2,'0D"
            year month day hour min sec)))

(defun universal-time->stamp (universal-time)
  "Render UNIVERSAL-TIME as a filesystem-safe YYYYMMDDHHMMSS stamp."
  (multiple-value-bind (sec min hour day month year)
      (decode-universal-time universal-time)
    (format nil "~4,'0D~2,'0D~2,'0D~2,'0D~2,'0D~2,'0D"
            year month day hour min sec)))

(defun histogram->hash-table (histogram)
  "Serialise HISTOGRAM to a string-keyed hash-table for JSON."
  (let ((table (make-hash-table :test 'equal)))
    (setf (gethash "count" table) (histogram-total-count histogram))
    (setf (gethash "min" table)
          (if (zerop (histogram-total-count histogram)) 0 (histogram-min histogram)))
    (setf (gethash "max" table) (histogram-max histogram))
    (setf (gethash "mean" table) (histogram-mean histogram))
    (setf (gethash "p50" table) (histogram-percentile histogram 0.50))
    (setf (gethash "p95" table) (histogram-percentile histogram 0.95))
    (setf (gethash "p99" table) (histogram-percentile histogram 0.99))
    (setf (gethash "buckets" table) (coerce (histogram-counts histogram) 'list))
    table))

(defun gc-log->hash-table ()
  "Serialise the GC log: total count, pause histogram, and the most
recent samples in the ring."
  (let ((table (make-hash-table :test 'equal))
        (log *gc-log*))
    (setf (gethash "count" table) (gc-log-count log))
    (setf (gethash "pause-us" table)
          (histogram->hash-table (gc-log-pause-histogram log)))
    (let* ((count (gc-log-count log))
           (n (min count +gc-ring-size+))
           (recent '()))
      (loop :for k :from 0 :below n
            :for i := (mod (- (gc-log-write-index log) 1 k) +gc-ring-size+)
            :do (let ((entry (make-hash-table :test 'equal)))
                  (setf (gethash "pause-us" entry) (aref (gc-log-pause-us log) i))
                  (setf (gethash "heap-after" entry) (aref (gc-log-heap-after log) i))
                  (push entry recent)))
      (setf (gethash "recent" table) (nreverse recent)))
    table))

(defun heap-log->list ()
  "Serialise the heap/RSS ring, oldest retained sample first."
  (let* ((log *heap-log*)
         (count (heap-log-count log))
         (n (min count +heap-ring-size+))
         (start (mod (- (heap-log-write-index log) n) +heap-ring-size+))
         (samples '()))
    (loop :for k :from 0 :below n
          :for i := (mod (+ start k) +heap-ring-size+)
          :do (let ((entry (make-hash-table :test 'equal)))
                (setf (gethash "t" entry) (aref (heap-log-seconds log) i))
                (setf (gethash "dynamic-usage" entry)
                      (aref (heap-log-dynamic-usage log) i))
                (setf (gethash "rss" entry) (aref (heap-log-rss log) i))
                (push entry samples)))
    (nreverse samples)))

(defun fingerprint->hash-table ()
  "Machine/lisp identity accompanying every dump (enough for PF-3 to key
comparisons; the bench runner extends it)."
  (let ((table (make-hash-table :test 'equal)))
    (setf (gethash "machine-instance" table) (machine-instance))
    (setf (gethash "machine-type" table) (machine-type))
    (setf (gethash "machine-version" table) (machine-version))
    (setf (gethash "lisp-implementation" table)
          (format nil "~A ~A"
                  (lisp-implementation-type)
                  (lisp-implementation-version)))
    table))

(defun metrics->hash-table ()
  "Build the full JSON-ready hash-table for the current metrics state."
  (let ((table (make-hash-table :test 'equal))
        (snapshot (aggregate-partitions))
        (now (get-universal-time)))
    (setf (gethash "schema" table) "lem-metrics/1")
    (setf (gethash "commit" table) (ignore-errors (lem-git-revision)))
    (setf (gethash "fingerprint" table) (fingerprint->hash-table))
    (setf (gethash "session-start" table)
          (when *session-start-universal-time*
            (universal-time->iso *session-start-universal-time*)))
    (setf (gethash "dumped-at" table) (universal-time->iso now))
    (setf (gethash "uptime-seconds" table)
          (if *session-start-universal-time*
              (- now *session-start-universal-time*)
              0))
    (let ((latency (make-hash-table :test 'equal)))
      (setf (gethash "keystroke-us" latency)
            (histogram->hash-table (snapshot-keystroke snapshot)))
      (setf (gethash "queue-wait-us" latency)
            (histogram->hash-table (snapshot-queue-wait snapshot)))
      (setf (gethash "redisplay-us" latency)
            (histogram->hash-table (snapshot-redisplay snapshot)))
      (setf (gethash "latency" table) latency))
    (let ((commands '()))
      (dolist (entry (sorted-command-entries snapshot))
        (let ((command (histogram->hash-table (cdr entry))))
          (setf (gethash "name" command)
                (string-downcase (symbol-name (car entry))))
          (push command commands)))
      (setf (gethash "commands" table) (nreverse commands)))
    (setf (gethash "command-overflow" table)
          (histogram->hash-table (snapshot-command-overflow snapshot)))
    (setf (gethash "gc" table) (gc-log->hash-table))
    (setf (gethash "heap-samples" table) (heap-log->list))
    table))

(defun metrics-directory ()
  "The (lem-home)/metrics/ directory, created if necessary."
  (let ((dir (merge-pathnames "metrics/" (lem-home))))
    (ensure-directories-exist dir)
    dir))

(defun dump-metrics-to-file (&optional pathname)
  "Serialise the current metrics to PATHNAME (default
(lem-home)/metrics/<session-start>.json) and return the pathname."
  (let ((path (or pathname
                  (merge-pathnames
                   (format nil "~A.json"
                           (universal-time->stamp
                            (or *session-start-universal-time*
                                (get-universal-time))))
                   (metrics-directory)))))
    (with-open-file (out path
                         :direction :output
                         :if-exists :supersede
                         :if-does-not-exist :create)
      (yason:encode (metrics->hash-table) out)
      (finish-output out))
    path))

;;;; ------------------------------------------------------------------
;;;; Human report
;;;; ------------------------------------------------------------------

(defun format-histogram-line (stream label histogram)
  (format stream
          "  ~20A n=~8D  min=~8D  p50=~8D  p95=~8D  p99=~8D  max=~8D~%"
          label
          (histogram-total-count histogram)
          (if (zerop (histogram-total-count histogram)) 0 (histogram-min histogram))
          (histogram-percentile histogram 0.50)
          (histogram-percentile histogram 0.95)
          (histogram-percentile histogram 0.99)
          (histogram-max histogram)))

(defun render-report (stream)
  "Write a human-readable metrics summary to STREAM."
  (let ((snapshot (aggregate-partitions)))
    (format stream "Lem T0 metrics report~%")
    (format stream "=====================~%")
    (when *session-start-universal-time*
      (format stream "session start : ~A~%"
              (universal-time->iso *session-start-universal-time*))
      (format stream "uptime        : ~D s~%"
              (- (get-universal-time) *session-start-universal-time*)))
    (format stream "recording     : ~:[off~;on~]~%~%" *metrics-recording-p*)
    (format stream "Latency (microseconds; log2-bucket estimates)~%")
    (format-histogram-line stream "keystroke->paint" (snapshot-keystroke snapshot))
    (format-histogram-line stream "queue-wait" (snapshot-queue-wait snapshot))
    (format-histogram-line stream "redisplay" (snapshot-redisplay snapshot))
    (format stream "~%Worst commands by total time~%")
    (let ((entries (sorted-command-entries snapshot)))
      (if (null entries)
          (format stream "  (none recorded)~%")
          (loop :for (name . histogram) :in entries
                :repeat 15
                :do (format-histogram-line stream
                                           (string-downcase (symbol-name name))
                                           histogram))))
    (when (plusp (histogram-total-count (snapshot-command-overflow snapshot)))
      (format-histogram-line stream "<overflow>"
                             (snapshot-command-overflow snapshot)))
    (format stream "~%GC~%")
    (format stream "  total GCs     : ~D~%" (gc-log-count *gc-log*))
    (format-histogram-line stream "gc-pause" (gc-log-pause-histogram *gc-log*))
    (format stream "~%Heap~%")
    (let* ((log *heap-log*)
           (count (heap-log-count log)))
      (if (zerop count)
          (format stream "  (no samples yet)~%")
          (let ((i (mod (1- (heap-log-write-index log)) +heap-ring-size+)))
            (format stream "  samples       : ~D~%" count)
            (format stream "  dynamic-usage : ~D bytes~%"
                    (aref (heap-log-dynamic-usage log) i))
            (format stream "  rss           : ~D bytes~%"
                    (aref (heap-log-rss log) i)))))
    (format stream "~%Note: percentiles are log2-bucket estimates (bounded error).~%")))

;;;; ------------------------------------------------------------------
;;;; Lifecycle and reset
;;;; ------------------------------------------------------------------

(defun reset-metrics ()
  "Discard all recorded data and start a fresh session.  Intended for
tests and for a deliberate restart of measurement."
  (bt2:with-lock-held (*partitions-lock*)
    (setf *partitions* '()))
  (setf *gc-log* (%make-gc-log))
  (setf *heap-log* (%make-heap-log))
  (setf *session-start-universal-time* (get-universal-time))
  (setf *session-start-internal-time* (get-internal-real-time))
  (values))

(defun start-metrics ()
  "Begin a recording session: mark the start, install the GC hook, and
start the heap/RSS idle timer.  Idempotent for the timer and hook."
  (setf *session-start-universal-time* (get-universal-time))
  (setf *session-start-internal-time* (get-internal-real-time))
  (install-gc-hook)
  (unless *heap-timer*
    (setf *heap-timer*
          (start-timer (make-idle-timer 'metrics-heap-sample
                                        :name "lem-metrics heap sampler")
                       (* *heap-sample-interval-seconds* 1000)
                       :repeat t)))
  (values))

(defun stop-metrics ()
  "Stop the heap/RSS idle timer.  The GC hook stays installed but honours
the recording gate; recording is disabled by the `record-metrics'
variable, not by this function."
  (when *heap-timer*
    (stop-timer *heap-timer*)
    (setf *heap-timer* nil))
  (values))

;;;; ------------------------------------------------------------------
;;;; Commands
;;;; ------------------------------------------------------------------

(define-command metrics-dump () ()
  "Write the current T0 telemetry to a JSON file under
(lem-home)/metrics/ and report the path in the echo area."
  (handler-case
      (let ((path (dump-metrics-to-file)))
        (message "Metrics written to ~A" path))
    (error (c)
      (editor-error "metrics-dump failed: ~A: ~A" (type-of c) c))))

(define-command metrics-report () ()
  "Render a human-readable summary of the current T0 telemetry
(latency percentiles, worst commands, GC pauses, heap trend) into the
*metrics* buffer and display it."
  (let ((buffer (make-buffer "*metrics*")))
    (erase-buffer buffer)
    (with-open-stream (stream (make-buffer-output-stream (buffer-point buffer)))
      (render-report stream))
    (buffer-start (buffer-point buffer))
    (pop-to-buffer buffer)))

;;;; ------------------------------------------------------------------
;;;; Automatic wiring (real editor sessions only)
;;;; ------------------------------------------------------------------

(add-hook *after-init-hook* 'start-metrics)

(add-hook *exit-editor-hook*
          (lambda ()
            (ignore-errors (dump-metrics-to-file))))
