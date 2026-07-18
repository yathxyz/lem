;;;; telemetry.lisp -- T1 entry: the PF-1 record path (SPEC-PERF PF-4).
;;;;
;;;; The permanent Constraint-4 canary: `lem/metrics:histogram-record' is the
;;;; always-on hot-path primitive the running editor calls on every recorded
;;;; event, and it must stay under 1 us/op and cons nothing.  This entry is
;;;; budget-gated (see `+budget-gated-entries+' in run-t1.lisp), not band-gated:
;;;; at ~0.8 ns/op the median-band comparison is non-reproducible.
;;;;
;;;; `histogram-record' is declaimed inline, so the closure below runs the exact
;;;; code the editor executes on the hot path.

(in-package :cl-user)

(defparameter *inner-ops* 50000000
  "Iterations per timed section for the telemetry entry.  The record path costs
sub-nanosecond per op, while `get-internal-real-time' resolves only to 1 us
(internal-time-units-per-second = 1e6 on SBCL/Linux).  A short loop (e.g. 1e6
ops ~= 0.8 ms window) times fewer than ~1000 clock ticks, so 1 tick of jitter
swings the per-op figure a full 2x and the median goes bimodal (0.001 vs
0.002).  50e6 ops widens the window to ~40 ms (~40000 ticks) so quantization
error drops below 0.01% and the reported per-op figure is an honest ~0.0008
us/op trend number instead of a quantized artifact.")

(defparameter *inject-inner-ops* 2000
  "Iterations per timed section when *inject-sleep-us* is set: each op
busy-waits, so the window is already milliseconds-wide and a large op count
would only make the self-test slow.")

(defun telemetry-setup ()
  "Fresh histogram per timed section.  Recording into a fresh vs a reused
histogram is identical cost (both just increment fixnum counters); a fresh one
keeps the section self-contained."
  (lem/metrics:make-histogram))

(defun telemetry-op (histogram count)
  "Drive the PF-1 record path COUNT times over HISTOGRAM.  Honours the
self-test injection (`*inject-sleep-us*') so the budget gate can be exercised."
  (declare (type fixnum count) (optimize (speed 3) (safety 1)))
  (let ((inject *inject-sleep-us*))
    (if inject
        (locally (declare (type fixnum inject))
          (dotimes (i count)
            (lem/metrics:histogram-record histogram 12345)
            (bench-busy-us inject)))
        (dotimes (i count)
          (lem/metrics:histogram-record histogram 12345)))))

(register-bench-entry
 :name "telemetry"
 :unit "us/op"
 :inner (if *inject-sleep-us* *inject-inner-ops* *inner-ops*)
 :setup #'telemetry-setup
 :op #'telemetry-op)
