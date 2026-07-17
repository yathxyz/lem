(defpackage :lem-tests/pbt/harness-test
  (:use :cl :rove :lem-tests/pbt/harness))
(in-package :lem-tests/pbt/harness-test)

;;; Meta-tests for the PBT harness itself (SPEC-VK V0-4 acceptance): a
;;; deliberately-failing property must shrink to a small counterexample and print
;;; a reproducing seed. These tests exercise the harness's failure-reporting
;;; machinery by capturing a property failure as data; none is permanently red.

;;; A deterministic failing property: "every drawn integer is < 500", over the
;;; range [0, 1000]. With a fixed seed and enough tests it always finds a
;;; counterexample, and greedy shrinking always lands on the boundary value 500.
(defun run-boundary-failure (&key (seed 20260717) (num-tests 200))
  (check-property (list (gen-integer :min 0 :max 1000))
                  (lambda (values) (< (first values) 500))
                  :seed seed :num-tests num-tests :name "n<500"))

(deftest deliberately-failing-property-shrinks-to-boundary
  ;; The acceptance criterion: failure detected, shrunk to the smallest failing
  ;; case (exactly 500), and the reproducing seed is retained.
  (let ((result (run-boundary-failure)))
    (ng (property-result-passed result))
    (ok (= 500 (first (property-result-shrunk result))))
    (ok (= 20260717 (property-result-seed result)))
    ;; The original counterexample was >= 500 and shrinking only made it smaller.
    (ok (>= (first (property-result-original result)) 500))
    (ok (<= (first (property-result-shrunk result))
            (first (property-result-original result))))))

(deftest seed-makes-runs-reproducible
  ;; Same seed => identical original and shrunk counterexamples.
  (let ((a (run-boundary-failure))
        (b (run-boundary-failure)))
    (ok (equal (property-result-original a) (property-result-original b)))
    (ok (equal (property-result-shrunk a) (property-result-shrunk b)))))

(deftest failure-report-prints-reproducing-seed
  (let* ((result (run-boundary-failure))
         (report (property-failure-report result)))
    (ok (search "FAILED" report))
    ;; The report names the env var and the exact seed needed to reproduce.
    (ok (search "LEM_PBT_SEED=20260717" report))
    (ok (search "Shrunk" report))))

(deftest passing-property-reports-success
  (let ((result (check-property (list (gen-integer :min 0 :max 100))
                                (lambda (values) (<= 0 (first values) 100))
                                :seed 1 :num-tests 100 :name "in-range")))
    (ok (property-result-passed result))
    (ok (= 100 (property-result-num-tests-run result)))))

;;; The `for-all' driver reports a real property failure through rove. We capture
;;; it in a private stats object so the failure is observed as data rather than
;;; failing this test.
(deftest for-all-records-rove-failure-on-false-property
  (let ((failed-count
          (let ((rove/core/stats:*stats* (make-instance 'rove/core/stats:stats))
                (*seed* 20260717)
                (*num-tests* 200))
            (for-all ((n (gen-integer :min 0 :max 1000)))
              (< n 500))
            (length (rove/core/stats:stats-failed-tests rove/core/stats:*stats*)))))
    (ok (plusp failed-count))))

;;; `for-all' integrates with rove for genuinely-true properties (these assertions
;;; count as ordinary passes in this suite).
(deftest for-all-passes-true-properties
  (for-all ((s (gen-string :max-length 30)))
    (string= s (reverse (reverse s))))
  (for-all ((v (gen-byte-stream :max-length 32)))
    (every (lambda (b) (<= 0 b 255)) v))
  (for-all ((n (gen-integer :min -100 :max 100)))
    (= n (- (- n)))))

;;; Generators produce values of the documented shapes, including the required
;;; multibyte / combining / emoji repertoire for strings.
(deftest generators-produce-expected-shapes
  (let ((rng (make-rng 7)))
    ;; Byte streams are octet vectors.
    (let ((v (draw (gen-byte-stream :min-length 4 :max-length 4) rng)))
      (ok (typep v '(simple-array (unsigned-byte 8) (*))))
      (ok (= 4 (length v))))
    ;; Edit scripts are lists of :insert / :delete ops.
    (let ((script (draw (gen-edit-script :max-ops 20) rng)))
      (ok (listp script))
      (ok (every (lambda (op) (member (first op) '(:insert :delete))) script)))
    ;; Buffer content joins to a string.
    (let ((lines (draw (gen-buffer-content) rng)))
      (ok (stringp (buffer-content->string lines)))))
  ;; Over many draws the unicode string generator emits non-ASCII code points.
  (let ((rng (make-rng 99))
        (saw-wide nil))
    (dotimes (i 200)
      (let ((s (draw (gen-string :min-length 5 :max-length 20) rng)))
        (when (some (lambda (ch) (> (char-code ch) 127)) s)
          (setf saw-wide t))))
    (ok saw-wide "unicode string generator emits multibyte/emoji code points")))
