;;;; tests/pbt/interrupt-stress.lisp -- SPEC-VK VK-8 acceptance suites.
;;;;
;;;; Three anchors pinning verified/interrupt-model.lisp to production
;;;; (src/buffer/interrupt.lisp):
;;;;
;;;;   1. MODEL PBT (in-image, shim-loaded kernel functions): random action
;;;;      traces through the certified step function -- wf-int holds and no
;;;;      torn (inside-critical) delivery is ever flagged; random balanced
;;;;      region traces restore enabled and the nesting stack exactly
;;;;      (exercises the same functions ACL2 certified, V0-3 shim fidelity).
;;;;
;;;;   2. SINGLE-THREADED DIFFERENTIAL: random region/poll/arrive trees are
;;;;      executed against the REAL production without-interrupts /
;;;;      check-interrupt / interrupt (calling `interrupt' in-thread is
;;;;      exactly what bt2:interrupt-thread does at that point), recording
;;;;      the model trace AS EXECUTED -- including :exit-abort actions for
;;;;      every region a delivery unwinds through.  The recorded trace is
;;;;      replayed through the certified model; delivery counts and the
;;;;      final *interrupts-enabled* / *interrupted* must match exactly.
;;;;
;;;;   3. THREADED STRESS (the VK-8 acceptance test): a worker thread runs
;;;;      instrumented nested production without-interrupts regions with
;;;;      check-interrupt polls while the controller fires ONE real
;;;;      bt2:interrupt-thread interrupt per run at randomized times, across
;;;;      LEM_INTERRUPT_STRESS_RUNS (default 1000) runs.  Assertions are
;;;;      deterministic counters/invariants, never schedule expectations:
;;;;        * exactly-once delivery per arrival (one arrival in flight per
;;;;          run; a deterministic drain flushes any stale pending flag
;;;;          before counting, so a double delivery cannot hide),
;;;;        * never inside a critical region except at an explicit
;;;;          check-interrupt poll (*depth* / *at-poll* instrumentation is
;;;;          dynamic-extent, so it is exact at the signal point),
;;;;        * final *interrupts-enabled* restoration and a clean pending
;;;;          flag after every run.
;;;;      Synchronization is semaphores and atomic counters -- the only
;;;;      sleep is the randomized interrupt-timing jitter, which is load,
;;;;      not synchronization; waits have generous (30 s) timeouts.
;;;;
;;;;   Plus a deterministic force test: production's (interrupt t) delivers
;;;;   immediately even inside an open region (the model's sanctioned
;;;;   force bypass), exactly once, with enabled restored afterwards.
;;;;
;;;; Instrumentation note: *depth* is bound INSIDE the region body, so it is
;;;; already unwound when the macro's exit deliver-check signals -- an exit
;;;; delivery is correctly observed at the enclosing depth, matching the
;;;; model's :exit action semantics.

(defpackage :lem-tests/pbt/interrupt-stress
  (:use :cl
        :rove
        :lem-tests/pbt/harness))
(in-package :lem-tests/pbt/interrupt-stress)

;;; ------------------------------------------------------------------
;;; Kernel loading (shim + certified interrupt-model book)
;;; ------------------------------------------------------------------

(defun repo-root ()
  (asdf:system-source-directory :lem-tests))

(defun ensure-kernel-loaded ()
  "Load the dual-load shim and the VK-8 interrupt-model book into this image once."
  (handler-bind ((warning #'muffle-warning))
    (unless (find-package "LEM/KERNEL")
      (load (merge-pathnames "verified/shim.lisp" (repo-root))))
    (let ((s (find-symbol "INT-RUN" "LEM/KERNEL")))
      (when (or (null s) (not (fboundp s)))
        (funcall (find-symbol "LOAD-VERIFIED-BOOK" "LEM/KERNEL")
                 "interrupt-model")))))

(defun kcall (name &rest args)
  "Call the certified kernel function NAME through the :lem/kernel surface."
  (let ((symbol (find-symbol name "LEM/KERNEL")))
    (unless (and symbol (fboundp symbol))
      (error "kernel function ~A is not loaded" name))
    (apply symbol args)))

;;; ------------------------------------------------------------------
;;; 1. Model PBT: invariants and nesting over random traces
;;; ------------------------------------------------------------------

(defun gen-action ()
  "A generator of single model actions, shrinking toward the inert (:poll)."
  (make-generator
   :sample (lambda (rng)
             (case (rng-below rng 6)
               (0 '(:enter))
               (1 '(:exit))
               (2 '(:exit-abort))
               (3 '(:poll))
               (4 '(:arrive nil))
               (t '(:arrive t))))
   :shrink (lambda (a) (if (equal a '(:poll)) '() (list '(:poll))))))

(defun gen-trace (&key (max-length 40))
  "A generator of arbitrary (not necessarily balanced) action traces."
  (gen-list (gen-action) :max-length max-length))

(defun random-balanced (rng budget)
  "A random net-balanced action list (every :exit/:exit-abort matches an
:enter within the list) of at most roughly BUDGET actions."
  (if (<= budget 0)
      '()
      (case (rng-below rng 4)
        (0 (append (list '(:enter))
                   (random-balanced rng (- budget 3))
                   (list (if (rng-boolean rng) '(:exit) '(:exit-abort)))
                   (random-balanced rng (- budget 4))))
        (1 (cons '(:poll) (random-balanced rng (- budget 1))))
        (2 (cons (list :arrive (rng-boolean rng))
                 (random-balanced rng (- budget 1))))
        (t '()))))

(defun gen-balanced-trace ()
  "A generator of net-balanced traces (no shrinking: balance must be kept)."
  (make-generator :sample (lambda (rng) (random-balanced rng 24))))

(deftest model-reachable-invariants
  (ensure-kernel-loaded)
  (for-all ((trace (gen-trace)))
    (let ((st (kcall "INT-RUN" (kcall "INT-INIT") trace)))
      (and (kcall "WF-INT" st)
           (not (kcall "IST-TORN" st))))))

(deftest model-nesting-restoration
  (ensure-kernel-loaded)
  (for-all ((prefix (gen-trace))
            (balanced (gen-balanced-trace)))
    (let* ((st (kcall "INT-RUN" (kcall "INT-INIT") prefix))
           (st2 (kcall "INT-RUN" st balanced)))
      (and (kcall "NET-BALANCED" balanced 0)
           (equal (kcall "IST-ENABLED" st2) (kcall "IST-ENABLED" st))
           (equal (kcall "IST-STACK" st2) (kcall "IST-STACK" st))))))

;;; ------------------------------------------------------------------
;;; 2. Single-threaded differential: production vs. model
;;; ------------------------------------------------------------------

(defvar *rec* '()
  "Reversed model trace recorded while executing a tree against production.")

(defun rec (action)
  (push action *rec*))

(defun exec-node (node)
  "Execute NODE against the REAL production interrupt operations, recording
the model actions as they actually happen (aborted region exits included)."
  (ecase (car node)
    (:region
     (rec '(:enter))
     (let ((body-done nil))
       (unwind-protect
            (lem/buffer/interrupt:without-interrupts
              (mapc #'exec-node (cdr node))
              (setf body-done t))
         ;; If the body completed, the macro's exit deliver-check ran (and
         ;; possibly signaled): that IS the model's :exit action.  If the
         ;; body was unwound by a delivery deeper inside, the dynamic
         ;; binding was restored without the check: :exit-abort.
         (rec (if body-done '(:exit) '(:exit-abort))))))
    (:poll
     (rec '(:poll))
     (lem/buffer/interrupt:check-interrupt))
    (:arrive
     ;; Calling `interrupt' in-thread is exactly what bt2:interrupt-thread
     ;; does at whatever point the interruption lands.
     (rec (list :arrive (cadr node)))
     (lem/buffer/interrupt:interrupt (cadr node)))))

(defun run-production-forest (forest)
  "Execute FOREST from a clean interrupt state, catching each delivered
editor-interrupt at the top (as the production command loop does).  Return
(values recorded-trace delivered-count final-enabled final-pending)."
  (let ((*rec* '())
        (delivered 0))
    (let ((lem/buffer/interrupt::*interrupts-enabled* t)
          (lem/buffer/interrupt::*interrupted* nil))
      (dolist (node forest)
        (handler-case (exec-node node)
          (lem/buffer/errors:editor-interrupt () (incf delivered))))
      (values (reverse *rec*)
              delivered
              lem/buffer/interrupt::*interrupts-enabled*
              lem/buffer/interrupt::*interrupted*))))

(defun random-node (rng depth)
  (let ((r (rng-below rng 100)))
    (cond ((and (< depth 3) (< r 40))
           (cons :region
                 (loop :repeat (rng-below rng 4)
                       :collect (random-node rng (1+ depth)))))
          ((< r 70) '(:poll))
          ((< r 95) '(:arrive nil))
          (t '(:arrive t)))))

(defun gen-node ()
  (make-generator :sample (lambda (rng) (random-node rng 0))))

(defun gen-forest ()
  (gen-list (gen-node) :min-length 1 :max-length 5))

(deftest production-vs-model-differential
  (ensure-kernel-loaded)
  (for-all ((forest (gen-forest)))
    (multiple-value-bind (trace delivered final-enabled final-pending)
        (run-production-forest forest)
      (let ((st (kcall "INT-RUN" (kcall "INT-INIT") trace)))
        (and (kcall "WF-INT" st)
             (not (kcall "IST-TORN" st))
             (= delivered (kcall "DELIVER-COUNT" (kcall "INT-INIT") trace))
             (eq (kcall "IST-ENABLED" st) final-enabled)
             (eq (kcall "IST-PENDING" st) final-pending))))))

;;; ------------------------------------------------------------------
;;; 3. Threaded stress: real threads + bt2:interrupt-thread
;;; ------------------------------------------------------------------

(defvar *depth* 0
  "Worker instrumentation: number of production without-interrupts regions
whose BODY is currently executing (bound inside the region body, so it is
already unwound at the macro's own exit deliver-check).")

(defvar *at-poll* nil
  "Worker instrumentation: true while inside an explicit check-interrupt poll.")

(defstruct stress-cell
  "Cross-thread channel for one stress run: semaphores for synchronization,
atomic counters for the deterministic assertions.  IN-CRITICAL-DELIVERIES
counts deliveries observed at *depth* > 0 outside a poll: the stress test
asserts it stays 0; the force test asserts exactly 1 (the sanctioned bypass)."
  (started (bt2:make-semaphore))
  (delivered-sem (bt2:make-semaphore))
  (stop (bt2:make-atomic-integer :value 0))
  (delivered (bt2:make-atomic-integer :value 0))
  (in-critical-deliveries (bt2:make-atomic-integer :value 0))
  (restore-violations (bt2:make-atomic-integer :value 0))
  (final-enabled nil)
  (final-pending :unset))

(defun stop-p (cell)
  (plusp (bt2:atomic-integer-value (stress-cell-stop cell))))

(defun stress-busy (n)
  "A little pure busy work so interruptions land mid-computation."
  (let ((x 0))
    (dotimes (i n x)
      (setf x (logxor x (1+ i))))))

(defun stress-poll ()
  (let ((*at-poll* t))
    (lem/buffer/interrupt:check-interrupt)))

(defun stress-region (level max-level)
  "A production without-interrupts region: busy work, optional nesting to
MAX-LEVEL, an explicit poll, more busy work."
  (lem/buffer/interrupt:without-interrupts
    (let ((*depth* (1+ *depth*)))
      (stress-busy 32)
      (when (< level max-level)
        (stress-region (1+ level) max-level))
      (stress-poll)
      (stress-busy 32))))

(defun stress-iteration (cell max-level)
  (stress-region 1 max-level)
  ;; Enabled-state restoration after every fully unwound region cycle.
  (unless (eq lem/buffer/interrupt::*interrupts-enabled* t)
    (bt2:atomic-integer-incf (stress-cell-restore-violations cell)))
  (stress-busy 64))

(defvar *delivery-snapshot* :none
  "Signal-point snapshot (list *depth* *at-poll*) taken by the handler-bind
observer in `with-delivery-observed'; consumed by the catch clause.")

(defun note-delivery-signal ()
  (setf *delivery-snapshot* (list *depth* *at-poll*)))

(defun count-delivery (cell)
  "Count one caught delivery and classify it via the signal-point snapshot.
A delivery with no snapshot was signaled in the few-instruction window inside
the handler-case but outside the handler-bind extent -- depth-0 harness glue,
not a critical region."
  (bt2:atomic-integer-incf (stress-cell-delivered cell))
  (let ((snapshot *delivery-snapshot*))
    (setf *delivery-snapshot* :none)
    (when (and (consp snapshot)
               (plusp (first snapshot))
               (not (second snapshot)))
      (bt2:atomic-integer-incf (stress-cell-in-critical-deliveries cell))))
  (bt2:signal-semaphore (stress-cell-delivered-sem cell)))

(defmacro with-delivery-observed ((cell) &body body)
  "Run BODY observing and absorbing editor-interrupt deliveries.  Counting
happens in the handler-case CLAUSE -- the only place guaranteed to run for
every caught delivery.  A handler-bind observer (registered inside the catch,
because handlers run innermost-first) additionally snapshots the dynamic
state at the signal point for the inside-critical classification; a delivery
signaled in the tiny establishment/return window where only the handler-case
is active still gets counted, with no snapshot (depth-0 glue by
construction).  Nested uses count each delivery exactly once: the innermost
catch transfers control before any outer handler is reached."
  `(handler-case
       (handler-bind ((lem/buffer/errors:editor-interrupt
                        (lambda (c)
                          (declare (ignore c))
                          (note-delivery-signal))))
         ,@body)
     (lem/buffer/errors:editor-interrupt ()
       (count-delivery ,cell))))

(defun stress-worker (cell max-level)
  "Worker body: run instrumented region cycles until told to stop, surviving
editor-interrupt deliveries anywhere; then deterministically drain any stale
pending flag and record the final interrupt state."
  (let ((*depth* 0)
        (*at-poll* nil)
        (*delivery-snapshot* :none))
    ;; COVERAGE DISCIPLINE: from the moment the controller may fire the
    ;; interrupt (the started signal) until the run's single arrival has been
    ;; executed, EVERY worker instruction must be inside a
    ;; with-delivery-observed catch -- an immediate delivery landing in
    ;; uncovered glue has no editor-interrupt handler and is silently
    ;; absorbed by the thread machinery (observed empirically: ~1/1000
    ;; runs).  Hence: started is signaled INSIDE the outer wrapper, and the
    ;; inner loop (tests included) runs inside it too.  The uncovered outer
    ;; re-entry glue below runs only after a caught delivery or after stop
    ;; -- in both cases the arrival has already been executed, so nothing
    ;; can land there.
    (loop
      (with-delivery-observed (cell)
        (bt2:signal-semaphore (stress-cell-started cell))
        (loop :until (stop-p cell)
              :do (with-delivery-observed (cell)
                    (stress-iteration cell max-level))))
      (when (stop-p cell)
        (return)))
    ;; Drain: flush a stale pending flag deterministically, so a wrongly
    ;; still-pending interrupt WILL surface as an extra delivery.
    (with-delivery-observed (cell)
      (stress-poll))
    (with-delivery-observed (cell)
      (lem/buffer/interrupt:without-interrupts nil))
    (setf (stress-cell-final-enabled cell)
          lem/buffer/interrupt::*interrupts-enabled*)
    (setf (stress-cell-final-pending cell)
          lem/buffer/interrupt::*interrupted*)))

(defun stress-run-once (rng)
  "One stress run: spawn a worker, fire ONE bt2:interrupt-thread interrupt at
a randomized time, wait (semaphore, generous timeout) for its delivery, stop
the worker, join, and return the run's result plist."
  (setf lem/buffer/interrupt::*interrupted* nil)
  (let* ((cell (make-stress-cell))
         (max-level (rng-range rng 1 3))
         (jitter-us (rng-below rng 1500))
         (thread (bt2:make-thread (lambda () (stress-worker cell max-level))
                                  :name "lem-interrupt-stress-worker")))
    (let ((started (bt2:wait-on-semaphore (stress-cell-started cell)
                                          :timeout 30)))
      (when (plusp jitter-us)
        (sleep (/ jitter-us 1000000.0)))
      (bt2:interrupt-thread thread #'lem/buffer/interrupt:interrupt)
      (let ((delivered-in-time
              (bt2:wait-on-semaphore (stress-cell-delivered-sem cell)
                                     :timeout 30)))
        (bt2:atomic-integer-incf (stress-cell-stop cell))
        (bt2:join-thread thread)
        (list :started (and started t)
              :in-time (and delivered-in-time t)
              :delivered (bt2:atomic-integer-value (stress-cell-delivered cell))
              :in-critical
              (bt2:atomic-integer-value (stress-cell-in-critical-deliveries cell))
              :restore-violations
              (bt2:atomic-integer-value (stress-cell-restore-violations cell))
              :final-enabled (eq (stress-cell-final-enabled cell) t)
              :final-pending-clear (null (stress-cell-final-pending cell)))))))

(defparameter *stress-runs-env-var* "LEM_INTERRUPT_STRESS_RUNS"
  "Environment variable overriding the number of threaded stress runs.")

(defun stress-runs ()
  (let ((env (uiop:getenv *stress-runs-env-var*)))
    (or (and env (ignore-errors (parse-integer (string-trim " " env))))
        1000)))

(deftest threaded-interrupt-stress
  (let* ((runs (stress-runs))
         (seed (or *seed* (default-seed)))
         (rng (make-rng seed))
         (not-started 0)
         (not-in-time 0)
         (wrong-delivery-count 0)
         (critical-violations 0)
         (restore-violations 0)
         (bad-final-state 0)
         (start-time (get-internal-real-time)))
    (dotimes (i runs)
      (let ((result (stress-run-once rng)))
        (unless (getf result :started) (incf not-started))
        (unless (getf result :in-time) (incf not-in-time))
        (unless (= 1 (getf result :delivered)) (incf wrong-delivery-count))
        (incf critical-violations (getf result :in-critical))
        (incf restore-violations (getf result :restore-violations))
        (unless (and (getf result :final-enabled)
                     (getf result :final-pending-clear))
          (incf bad-final-state))))
    (let ((elapsed (/ (- (get-internal-real-time) start-time)
                      internal-time-units-per-second)))
      (format t "~&interrupt-stress: ~D runs in ~,1Fs (seed ~D; reproduce with ~A=~D)~%"
              runs elapsed seed *seed-env-var* seed)
      (ok (zerop not-started)
          (format nil "every worker started (~D failures)" not-started))
      (ok (zerop not-in-time)
          (format nil "every arrival delivered within timeout (~D failures)"
                  not-in-time))
      (ok (zerop wrong-delivery-count)
          (format nil "exactly-once delivery per arrival across ~D runs (~D violations)"
                  runs wrong-delivery-count))
      (ok (zerop critical-violations)
          (format nil "no delivery inside a critical region except at a poll (~D violations)"
                  critical-violations))
      (ok (zerop restore-violations)
          (format nil "interrupts re-enabled after every region cycle (~D violations)"
                  restore-violations))
      (ok (zerop bad-final-state)
          (format nil "final state enabled with pending clear in every run (~D violations)"
                  bad-final-state)))))

;;; ------------------------------------------------------------------
;;; Force semantics against production: immediate delivery inside a region
;;; ------------------------------------------------------------------

(deftest force-interrupt-bypasses-deferral
  (setf lem/buffer/interrupt::*interrupted* nil)
  (let* ((in-region (bt2:make-semaphore))
         (cell (make-stress-cell))
         (thread
           (bt2:make-thread
            (lambda ()
              (let ((*depth* 0)
                    (*at-poll* nil)
                    (*delivery-snapshot* :none))
                (with-delivery-observed (cell)
                  (lem/buffer/interrupt:without-interrupts
                    (let ((*depth* (1+ *depth*)))
                      (bt2:signal-semaphore in-region)
                      ;; Spin inside the open region until the forced
                      ;; interrupt errors us out (or the controller gives
                      ;; up and stops the spin).
                      (loop :until (stop-p cell)
                            :do (stress-busy 64)))))
                (setf (stress-cell-final-enabled cell)
                      lem/buffer/interrupt::*interrupts-enabled*)
                (setf (stress-cell-final-pending cell)
                      lem/buffer/interrupt::*interrupted*)))
            :name "lem-interrupt-force-worker")))
    (ok (bt2:wait-on-semaphore in-region :timeout 30)
        "worker entered the critical region")
    (bt2:interrupt-thread thread #'lem/buffer/interrupt:interrupt t)
    (ok (bt2:wait-on-semaphore (stress-cell-delivered-sem cell) :timeout 30)
        "forced interrupt delivered while the region was open")
    (bt2:atomic-integer-incf (stress-cell-stop cell))
    (bt2:join-thread thread)
    (ok (= 1 (bt2:atomic-integer-value (stress-cell-delivered cell)))
        "forced interrupt delivered exactly once")
    (ok (= 1 (bt2:atomic-integer-value
              (stress-cell-in-critical-deliveries cell)))
        "the forced delivery bypassed deferral (landed inside the region)")
    (ok (eq (stress-cell-final-enabled cell) t)
        "interrupts re-enabled after the forced unwind")
    (ok (null (stress-cell-final-pending cell))
        "no stale pending flag after the forced delivery")))
