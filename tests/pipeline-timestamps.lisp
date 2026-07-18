(defpackage :lem-tests/pipeline-timestamps
  (:use :cl
        :rove
        :lem))
(in-package :lem-tests/pipeline-timestamps)

;;; SPEC-PERF PF-2: unit tests for the input->paint pipeline timestamps.
;;;
;;; The load-bearing property is the stage-sum conformance from the spec:
;;; on a keystroke the recorded stage deltas partition the end-to-end
;;; latency exactly, so
;;;
;;;   queue-wait (t2-t1) + command (t3-t2) + redisplay (t4-t3) = keystroke (t4-t1).
;;;
;;; Because every stamp comes from the same monotonic clock, this holds for
;;; any real t1<t2<t3<t4, which is what the driver below exercises.

(defmacro with-captured-stages ((var) &body body)
  "Install a pipeline sink that pushes each (STAGE VALUE NAME) onto VAR (bound
to a fresh list, chronological order after BODY), restoring the previous sink
and the in-flight stamps afterwards."
  (let ((old (gensym "OLD")))
    `(let ((,var '())
           (,old lem-core::*pipeline-recorder*))
       (unwind-protect
            (progn
              (set-pipeline-recorder
               (lambda (stage value name)
                 (setf ,var (nconc ,var (list (list stage value name))))))
              ,@body)
         (set-pipeline-recorder ,old)
         (setf lem-core::*pipeline-t1* nil
               lem-core::*pipeline-t2* nil
               lem-core::*pipeline-t3* nil)))))

(defun drive-keystroke (t1 command &optional (pause 0))
  "Drive one keystroke through the pipeline note functions as the editor
thread would: dequeue a `pipeline-event' enqueued at T1, finish COMMAND, and
finish the redisplay.  t2/t3/t4 are read from the real monotonic clock;
PAUSE seconds are slept between stages so the deltas are non-trivial.
Returns the unwrapped payload."
  (let* ((key (make-key :sym "a"))
         (payload (lem-core::note-event-dequeued
                   (lem-core::make-pipeline-event key 0 t1))))
    (when (plusp pause) (sleep pause))
    (lem-core::note-command-done command)
    (when (plusp pause) (sleep pause))
    (lem-core::note-redisplay-done)
    payload))

(defun stage-value (stages stage)
  (second (assoc stage stages)))

;;;; Stage-sum conformance --------------------------------------------

(deftest stage-sum-conformance
  ;; The four recorded stage deltas must partition the end-to-end latency
  ;; exactly (SPEC-PERF PF-2 "done when": total = sum of stages).
  (with-captured-stages (stages)
    ;; Space t1..t4 apart so each delta is provably non-zero: an all-zero
    ;; recording would satisfy the sum identity too, and must not pass here.
    (let ((t1 (pipeline-now)))
      (sleep 0.001)
      (drive-keystroke t1 'next-line 0.001))
    (let ((q (stage-value stages :queue-wait))
          (c (stage-value stages :command))
          (r (stage-value stages :redisplay))
          (k (stage-value stages :keystroke)))
      (ok (every #'integerp (list q c r k))
          "all four stages were recorded")
      (ok (and (plusp q) (plusp c) (plusp r) (plusp k))
          (format nil "every stage delta is strictly positive: ~D ~D ~D ~D"
                  q c r k))
      (ok (= (+ q c r) k)
          (format nil "stage sum ~D+~D+~D=~D must equal keystroke ~D"
                  q c r (+ q c r) k)))))

(deftest command-stage-carries-name
  (with-captured-stages (stages)
    (drive-keystroke (pipeline-now) 'my-test-command)
    (ok (eq 'my-test-command (third (assoc :command stages)))
        "the command stage is keyed by the command name")))

;;;; Unwrapping -------------------------------------------------------

(deftest dequeue-unwraps-payload
  (with-captured-stages (stages)
    (let* ((key (make-key :sym "x"))
           (event (lem-core::make-pipeline-event key 0 (pipeline-now))))
      (ok (eq key (lem-core::note-event-dequeued event))
          "a pipeline event is unwrapped to its payload")))
  ;; Non-wrapped objects pass through untouched.
  (ok (eq :resize (lem-core::note-event-dequeued :resize)))
  (ok (null (lem-core::note-event-dequeued nil)))
  (let ((k (make-key :sym "y")))
    (ok (eq k (lem-core::note-event-dequeued k)))))

;;;; Fire-once semantics ----------------------------------------------

(deftest keystroke-charged-exactly-once
  (with-captured-stages (stages)
    (drive-keystroke (pipeline-now) 'next-line)
    (ok (= 1 (count :keystroke stages :key #'first))
        "one keystroke produced exactly one keystroke sample")
    ;; Stamps are cleared, so a stray extra redisplay records nothing more.
    (let ((before (length stages)))
      (lem-core::note-redisplay-done)
      (lem-core::note-command-done 'next-line)
      (ok (= before (length stages))
          "no keystroke in flight => no further stage records"))))

;;;; Guard when telemetry is off --------------------------------------

(deftest guarded-when-no-recorder
  (let ((old lem-core::*pipeline-recorder*))
    (unwind-protect
         (progn
           (set-pipeline-recorder nil)
           (ok (not (pipeline-recording-p))
               "no recorder => not recording")
           ;; Unwrapping must still work with the recorder removed.
           (let ((key (make-key :sym "z")))
             (ok (eq key (lem-core::note-event-dequeued
                          (lem-core::make-pipeline-event key 0 42))))
             ;; ...and the command/redisplay notes are pure no-ops.
             (lem-core::note-command-done 'next-line)
             (lem-core::note-redisplay-done)
             (ok t "notes are no-ops without a recorder")))
      (set-pipeline-recorder old))))

;;;; End-to-end through the real T0 histograms ------------------------

(deftest records-into-real-histograms
  ;; With the metrics sink installed, a driven keystroke lands one sample in
  ;; each latency histogram and one in the command table.
  (lem/metrics:reset-metrics)
  (let ((old lem-core::*pipeline-recorder*))
    (unwind-protect
         (progn
           (lem/metrics::%sync-pipeline-recorder)
           (drive-keystroke (pipeline-now) 'records-into-real-histograms-cmd)
           (let ((snapshot (lem/metrics::aggregate-partitions)))
             (ok (= 1 (lem/metrics:histogram-total-count
                       (lem/metrics::snapshot-keystroke snapshot))))
             (ok (= 1 (lem/metrics:histogram-total-count
                       (lem/metrics::snapshot-queue-wait snapshot))))
             (ok (= 1 (lem/metrics:histogram-total-count
                       (lem/metrics::snapshot-redisplay snapshot))))
             (ok (gethash 'records-into-real-histograms-cmd
                          (lem/metrics::snapshot-commands snapshot))
                 "the command was recorded by name")))
      (set-pipeline-recorder old))))
