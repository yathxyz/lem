(defpackage :lem-tests/metrics
  (:use :cl
        :rove
        :lem/metrics))
(in-package :lem-tests/metrics)

;;; SPEC-PERF PF-1: unit tests for the T0 telemetry core.
;;; Covers histogram math, the Constraint-4 zero-consing budget on the
;;; record path, the JSON dump round-trip, and command-table overflow.

(defun measure-consed (thunk)
  "Return the bytes consed while running THUNK.  `get-bytes-consed' is a
cumulative allocation counter, so a GC firing inside THUNK does not
perturb the delta; we deliberately do NOT force a GC first, since the
post-GC TLAB accounting would add a fixed offset that hides the true
per-event figure."
  (let ((before (sb-ext:get-bytes-consed)))
    (funcall thunk)
    (- (sb-ext:get-bytes-consed) before)))

;;;; Histogram math ---------------------------------------------------

(deftest histogram-empty
  (let ((h (make-histogram)))
    (ok (zerop (histogram-total-count h)))
    (ok (zerop (histogram-percentile h 0.5)))
    (ok (zerop (histogram-percentile h 0.99)))))

(deftest histogram-basic-counts
  (let ((h (make-histogram)))
    (dotimes (i 1000) (histogram-record h (1+ i)))
    (ok (= 1000 (histogram-total-count h)))
    (ok (= 1 (histogram-min h)))
    (ok (= 1000 (histogram-max h)))
    ;; percentiles are log2-bucket upper edges: monotone and bracketing.
    (let ((p50 (histogram-percentile h 0.50))
          (p95 (histogram-percentile h 0.95))
          (p99 (histogram-percentile h 0.99)))
      (ok (<= p50 p95))
      (ok (<= p95 p99))
      ;; the true median (500) must sit at or below its bucket upper edge.
      (ok (>= p50 500))
      ;; and within one power of two of it.
      (ok (<= p50 1024)))))

(deftest histogram-bucketing-and-clamp
  ;; Values landing in the same log2 bucket share a percentile estimate;
  ;; values past the top bucket clamp into it rather than overflowing the
  ;; counts vector.  (2^40 us has integer-length 41 > 32 buckets.)
  (let ((h (make-histogram))
        (huge (ash 1 40)))
    (histogram-record h 0)
    (histogram-record h 1)
    (histogram-record h 3)
    (histogram-record h huge)
    (ok (= 4 (histogram-total-count h)))
    (ok (= 0 (histogram-min h)))
    (ok (= huge (histogram-max h)))
    ;; the clamped value lands in the final bucket.
    (ok (plusp (aref (lem/metrics::histogram-counts h)
                     (1- lem/metrics::+histogram-buckets+))))))

(deftest histogram-negative-treated-as-zero
  (let ((h (make-histogram)))
    (histogram-record h -5)
    (ok (= 1 (histogram-total-count h)))
    (ok (= 0 (histogram-min h)))))

(deftest histogram-merge
  (let ((a (make-histogram))
        (b (make-histogram)))
    (dotimes (i 10) (histogram-record a 100))
    (dotimes (i 5) (histogram-record b 100000))
    (histogram-merge-into a b)
    (ok (= 15 (histogram-total-count a)))
    (ok (= 100 (histogram-min a)))
    (ok (= 100000 (histogram-max a)))))

;;;; Zero-consing budget (Constraint 4) -------------------------------

(deftest histogram-record-conses-nothing
  ;; The core hot-path primitive must allocate zero bytes per event, or
  ;; the instrumentation becomes the perturbation it exists to measure.
  (let ((h (make-histogram)))
    (histogram-record h 5)              ; warm up / force compilation
    (let ((consed (measure-consed
                   (lambda ()
                     (dotimes (i 100000)
                       (histogram-record h 12345))))))
      (ok (zerop consed)
          (format nil "histogram-record consed ~D bytes over 100k events"
                  consed)))))

(deftest record-command-duration-conses-nothing
  ;; The full entry point (partition lookup + command table + record) must
  ;; also stay allocation-free once the command name is known.
  (reset-metrics)
  (record-command-duration 'existing-command 1)
  (let ((consed (measure-consed
                 (lambda ()
                   (dotimes (i 100000)
                     (record-command-duration 'existing-command 42))))))
    (ok (zerop consed)
        (format nil "record-command-duration consed ~D bytes over 100k events"
                consed))))

;;;; Command-table overflow -------------------------------------------

(deftest command-table-overflow
  ;; More distinct command names than the per-partition capacity fold into
  ;; a shared overflow histogram; the tracked-name table stays bounded.
  (reset-metrics)
  (let ((total 400))
    (dotimes (i total)
      (record-command-duration (intern (format nil "OVERFLOW-CMD-~D" i) :keyword)
                               7))
    (let* ((snapshot (lem/metrics::aggregate-partitions))
           (tracked (hash-table-count (lem/metrics::snapshot-commands snapshot)))
           (overflow (histogram-total-count
                      (lem/metrics::snapshot-command-overflow snapshot))))
      (ok (= tracked lem/metrics::+command-table-capacity+))
      (ok (= overflow (- total lem/metrics::+command-table-capacity+)))
      (ok (= total (+ tracked overflow))))))

;;;; JSON dump round-trip ---------------------------------------------

(deftest dump-round-trip
  (reset-metrics)
  (record-keystroke-latency 1500)
  (record-keystroke-latency 3000)
  (record-redisplay-duration 800)
  (record-command-duration 'my-command 250)
  (let* ((path (merge-pathnames "lem-metrics-test.json"
                                (uiop:temporary-directory)))
         (returned (dump-metrics-to-file path)))
    (unwind-protect
         (progn
           (ok (uiop:pathname-equal returned path))
           (ok (probe-file path))
           (let ((parsed (with-open-file (in path) (yason:parse in))))
             (ok (equal "lem-metrics/1" (gethash "schema" parsed)))
             (let ((keystroke (gethash "keystroke-us"
                                       (gethash "latency" parsed))))
               (ok (= 2 (gethash "count" keystroke)))
               (ok (= 1500 (gethash "min" keystroke))))
             (let ((redisplay (gethash "redisplay-us"
                                       (gethash "latency" parsed))))
               (ok (= 1 (gethash "count" redisplay))))
             ;; the recorded command survives serialisation by name.
             (let ((commands (gethash "commands" parsed)))
               (ok (find "my-command" commands
                         :key (lambda (c) (gethash "name" c))
                         :test #'equal)))
             ;; bucket vector is present and correctly sized.
             (let ((buckets (gethash "buckets"
                                     (gethash "keystroke-us"
                                              (gethash "latency" parsed)))))
               (ok (= lem/metrics::+histogram-buckets+ (length buckets))))))
      (ignore-errors (delete-file path)))))

;;;; Partition-by-writer ----------------------------------------------

(deftest current-partition-is-per-thread
  ;; Each writer thread gets its own partition, so increments need no lock.
  (reset-metrics)
  (let ((main (current-partition))
        (other nil))
    (let ((thread (bt2:make-thread
                   (lambda () (setf other (current-partition))))))
      (bt2:join-thread thread))
    (ok (not (eq main other))
        "distinct threads must receive distinct partitions")))
