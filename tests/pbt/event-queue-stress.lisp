;;;; tests/pbt/event-queue-stress.lisp -- SPEC-VK VK-9 acceptance suites.
;;;;
;;;; Four anchors pinning verified/event-queue-model.lisp to production
;;;; (src/event-queue.lisp + src/common/queue.lisp + src/common/timer.lisp):
;;;;
;;;;   1. MODEL PBT (in-image, shim-loaded kernel functions): random
;;;;      enqueue/dequeue traces through the certified step function -- wf-eq
;;;;      holds, the enqueue log always decomposes as dequeue-log ++ queue,
;;;;      executed thunks equal the thunk subsequence of the dequeue log,
;;;;      per-producer FIFO (prefix while in flight, equality after a drain),
;;;;      and a drain's update count is exactly eq-resize-tail-count.
;;;;
;;;;   2. SINGLE-THREADED DIFFERENTIAL: random and fixed enqueue/receive
;;;;      scripts run against the REAL production machinery -- a real
;;;;      `concurrent-queue' bound as `*editor-event-queue*', events sent
;;;;      through the real `send-event' and consumed by the real
;;;;      `receive-event' -- and replayed through the kernel model; returned
;;;;      events, executed-thunk order, update-on-display-resized call count
;;;;      and final queue length must match exactly.  The fixed vectors pin
;;;;      production's EXACT coalescing rule (process iff <= 1 events remain
;;;;      after the pop), including the terminal-burst-of-two -> TWO updates
;;;;      behavior that refutes the spec's "exactly one per burst" (recorded
;;;;      in the book header per Constraint 5).
;;;;
;;;;      TEST-ONLY PATCH: `update-on-display-resized' needs a live editor
;;;;      (frames, an implementation), so `call-with-counted-resizes'
;;;;      temporarily replaces its fdefinition with a counter and restores the
;;;;      original in an unwind-protect.  receive-event calls it late-bound
;;;;      across files, so the patch is what the real dequeue loop invokes.
;;;;
;;;;   3. THREADED STRESS (the VK-9 acceptance test): N real producer threads
;;;;      x M tagged events each (returned conses + thunks, with randomized
;;;;      :resize bursts) through the real concurrent-queue via the real
;;;;      send-event, one consumer thread running the real receive-event.
;;;;      DETERMINISTIC invariants only (no schedule expectations, no sleeps;
;;;;      the only yields are interleaving load):
;;;;        * conservation: every tagged event arrives exactly once
;;;;          (returned + thunk-executed = N*M, no duplicates),
;;;;        * per-producer FIFO: each producer's tags arrive in exact
;;;;          enqueue order (0..M-1),
;;;;        * thunks execute on the consumer thread only,
;;;;        * resize accounting: updates <= resizes enqueued, and >= 1 via a
;;;;          deterministic sentinel (a :resize enqueued after all producers
;;;;          have joined is the queue's last entry, so its pop always sees
;;;;          <= 1 remaining and must be processed),
;;;;        * the queue drains empty.
;;;;      Synchronization: semaphore-free -- producers are joined, the done
;;;;      flag is atomic, the consumer exits on (done AND drained) with a
;;;;      generous 60 s wall-clock guard.  Seeded via LEM_PBT_SEED; run count
;;;;      via LEM_EVENT_QUEUE_STRESS_RUNS (default 8).
;;;;
;;;;   4. TIMER: (a) model PBT of the certified idle-timer arithmetic
;;;;      (sleep-bound, fires-iff-overdue, ms-granularity boundary,
;;;;      partition); (b) SIMULATED-CLOCK DIFFERENTIAL reusing
;;;;      tests/common/timer.lisp's testing-timer-manager: random timer
;;;;      schedules stepped over a virtual ms clock across multiple idle
;;;;      periods, comparing production `get-next-timer-timing-ms' /
;;;;      `update-idle-timers' decisions (sleep value, fired set, surviving
;;;;      and processed lists, last-time bookkeeping) against the kernel's
;;;;      kt-next-timing / kt-fired / kt-remaining / kt-processed.
;;;;      Fired/remaining/processed are compared as id SETS per tick:
;;;;      production prunes with SET-DIFFERENCE, whose order is unspecified
;;;;      (see the book header's order caveat).
;;;;
;;;;      PRODUCTION BUG FOUND (pinned by `timer-double-fire-reproducer',
;;;;      documented not fixed): update-idle-timers can RE-FIRE
;;;;      already-processed repeat idle timers within the same idle period
;;;;      through remove-if-not structure sharing + nconc (mechanism in the
;;;;      reproducer's comment and the book header).  The differential
;;;;      accepts the clean and the double-fire outcome under the exact
;;;;      envelope condition (some fired timer is repeat AND the processed
;;;;      list is non-empty), because the trigger depends on production's
;;;;      unobservable internal list order; bookkeeping is asserted exactly
;;;;      in both cases.

(defpackage :lem-tests/pbt/event-queue-stress
  (:use :cl
        :rove
        :lem-tests/pbt/harness))
(in-package :lem-tests/pbt/event-queue-stress)

;;; ------------------------------------------------------------------
;;; Kernel loading (shim + certified event-queue-model book)
;;; ------------------------------------------------------------------

(defun repo-root ()
  (asdf:system-source-directory :lem-tests))

(defun ensure-kernel-loaded ()
  "Load the dual-load shim and the VK-9 event-queue-model book into this image once."
  (handler-bind ((warning #'muffle-warning))
    (unless (find-package "LEM/KERNEL")
      (load (merge-pathnames "verified/shim.lisp" (repo-root))))
    (let ((s (find-symbol "EQ-RUN" "LEM/KERNEL")))
      (when (or (null s) (not (fboundp s)))
        (funcall (find-symbol "LOAD-VERIFIED-BOOK" "LEM/KERNEL")
                 "event-queue-model")))))

(defun kcall (name &rest args)
  "Call the certified kernel function NAME through the :lem/kernel surface."
  (let ((symbol (find-symbol name "LEM/KERNEL")))
    (unless (and symbol (fboundp symbol))
      (error "kernel function ~A is not loaded" name))
    (apply symbol args)))

;;; ------------------------------------------------------------------
;;; 1. Model PBT: invariants over random enqueue/dequeue traces
;;; ------------------------------------------------------------------

(defun gen-model-item ()
  "A generator of model queue items (see the book header's item alphabet)."
  (make-generator
   :sample (lambda (rng)
             (let ((r (rng-below rng 100)))
               (cond ((< r 40) (list :event (rng-below rng 50)))
                     ((< r 60) (list :thunk (rng-below rng 50)))
                     ((< r 90) :resize)
                     (t :null))))))

(defun gen-model-action ()
  "A generator of single model actions, shrinking toward the inert (:dequeue)."
  (let ((item-gen (gen-model-item)))
    (make-generator
     :sample (lambda (rng)
               (if (< (rng-below rng 100) 55)
                   (list :enqueue (rng-below rng 4) (draw item-gen rng))
                   '(:dequeue)))
     :shrink (lambda (a) (if (equal a '(:dequeue)) '() (list '(:dequeue)))))))

(defun gen-model-trace ()
  (gen-list (gen-model-action) :max-length 40))

(deftest model-reachable-invariants
  (ensure-kernel-loaded)
  (for-all ((trace (gen-model-trace)))
    (let ((st (kcall "EQ-RUN" (kcall "EQ-INIT") trace)))
      (and (kcall "WF-EQ" st)
           ;; no loss: everything enqueued is dequeued (in order) or queued
           (equal (kcall "EQS-ENQ-LOG" st)
                  (append (kcall "EQS-DEQ-LOG" st) (kcall "EQS-QUEUE" st)))
           ;; thunks run exactly at their dequeue, in dequeue order
           (equal (kcall "EQS-THUNKS" st)
                  (kcall "EQ-THUNK-TAGS" (kcall "EQS-DEQ-LOG" st)))
           ;; entry records round-trip through their accessors
           (loop :for e :in (kcall "EQS-ENQ-LOG" st)
                 :always (equal e (kcall "MK-ENTRY"
                                         (kcall "ENTRY-PRODUCER" e)
                                         (kcall "ENTRY-ITEM" e))))))))

(deftest model-per-producer-fifo
  (ensure-kernel-loaded)
  (for-all ((trace (gen-model-trace)))
    (let* ((st (kcall "EQ-RUN" (kcall "EQ-INIT") trace))
           (drained (kcall "EQ-DRAIN" st)))
      (loop :for p :below 4
            :always
            (and ;; in flight: dequeues are a prefix of enqueues, per producer
                 (kcall "EQM-PREFIXP"
                        (kcall "EQ-BY-PRODUCER" p (kcall "EQS-DEQ-LOG" st))
                        (kcall "EQ-BY-PRODUCER" p (kcall "EQS-ENQ-LOG" st)))
                 ;; drained: exact per-producer equality
                 (equal (kcall "EQ-BY-PRODUCER" p (kcall "EQS-DEQ-LOG" drained))
                        (kcall "EQ-BY-PRODUCER" p (kcall "EQS-ENQ-LOG" drained))))))))

(deftest model-drain-coalescing
  (ensure-kernel-loaded)
  (for-all ((trace (gen-model-trace)))
    (let* ((st (kcall "EQ-RUN" (kcall "EQ-INIT") trace))
           (drained (kcall "EQ-DRAIN" st)))
      (and (null (kcall "EQS-QUEUE" drained))
           ;; the drain processes exactly the resizes with <= 1 entries behind
           (= (kcall "EQS-UPDATES" drained)
              (+ (kcall "EQS-UPDATES" st)
                 (kcall "EQ-RESIZE-TAIL-COUNT" (kcall "EQS-QUEUE" st))))
           ;; and dequeues everything exactly once
           (equal (kcall "EQS-DEQ-LOG" drained)
                  (kcall "EQS-ENQ-LOG" drained))))))

;;; ------------------------------------------------------------------
;;; The test-only update-on-display-resized counter patch
;;; ------------------------------------------------------------------

(defparameter *update-fn-symbol* 'lem-core::update-on-display-resized
  "The production function receive-event calls on a processed :resize.")

(defun %set-update-fn (fn)
  #+sbcl (sb-ext:with-unlocked-packages (:lem-core)
           (setf (fdefinition *update-fn-symbol*) fn))
  #-sbcl (setf (fdefinition *update-fn-symbol*) fn))

(defun call-with-counted-resizes (fn)
  "Run FN with update-on-display-resized replaced by a thread-safe counter
\(the real one needs a live editor).  FN receives a zero-argument reader for
the current count.  The original fdefinition is restored in an unwind-protect."
  (let ((original (fdefinition *update-fn-symbol*))
        (count (bt2:make-atomic-integer :value 0)))
    (%set-update-fn (lambda () (bt2:atomic-integer-incf count)))
    (unwind-protect
         (funcall fn (lambda () (bt2:atomic-integer-value count)))
      (%set-update-fn original))))

;;; ------------------------------------------------------------------
;;; 2. Single-threaded differential: real send/receive-event vs. the model
;;; ------------------------------------------------------------------
;;;
;;; A script is a list of (:enqueue producer item) / (:receive) steps, items
;;; in the model alphabet: (:event tag) | (:thunk tag) | :resize | :null.

(defun realize-item (item thunk-cell)
  "The production object for a model ITEM: (:event tag) conses travel (and
return) as themselves, thunks become closures recording their tag, :null is
an enqueued NIL."
  (cond ((eq item :resize) :resize)
        ((eq item :null) nil)
        ((and (consp item) (eq (car item) :thunk))
         (let ((tag (cadr item)))
           (lambda () (push tag (car thunk-cell)))))
        (t item)))

(defun run-real-script (script)
  "Execute SCRIPT against the real queue + send-event/receive-event.
Returns a plist of the observables."
  (call-with-counted-resizes
   (lambda (get-count)
     (let ((thunk-cell (list nil))
           (returns '())
           (lem-core::*editor-event-queue*
             (lem/common/queue:make-concurrent-queue)))
       (dolist (step script)
         (ecase (car step)
           (:enqueue
            (lem-core:send-event (realize-item (third step) thunk-cell)))
           (:receive
            (push (or (lem-core:receive-event 0.005) :nil) returns))))
       (list :returns (nreverse returns)
             :thunks (reverse (car thunk-cell))
             :updates (funcall get-count)
             :qlen (lem-core:event-queue-length))))))

(defun model-receive (st)
  "One receive-event call against the kernel model: dequeue steps until an
event or :null returns, or the queue empties (the timeout).  Returns
(values st* returned) with RETURNED the item or :nil."
  (loop
    (let ((queue (kcall "EQS-QUEUE" st)))
      (if (null queue)
          (return (values st :nil))
          (let ((item (kcall "ENTRY-ITEM" (car queue))))
            (setf st (kcall "EQ-STEP" st '(:dequeue)))
            (cond ((eq item :null) (return (values st :nil)))
                  ((eq item :resize))                       ; loop
                  ((and (consp item) (eq (car item) :thunk))) ; loop
                  (t (return (values st item)))))))))

(defun run-model-script (script)
  "Execute SCRIPT against the certified model.  Same observables plist."
  (let ((st (kcall "EQ-INIT"))
        (returns '()))
    (dolist (step script)
      (ecase (car step)
        (:enqueue
         (setf st (kcall "EQ-STEP" st (list :enqueue (second step) (third step)))))
        (:receive
         (multiple-value-bind (st* ret) (model-receive st)
           (setf st st*)
           (push ret returns)))))
    (list :returns (nreverse returns)
          :thunks (kcall "EQS-THUNKS" st)
          :updates (kcall "EQS-UPDATES" st)
          :qlen (length (kcall "EQS-QUEUE" st)))))

(deftest receive-event-fixed-vectors
  (ensure-kernel-loaded)
  ;; Each vector: script, expected observables.  These pin production's exact
  ;; coalescing rule -- including the terminal-burst-of-two -> TWO updates
  ;; case that refutes the naive "one update per burst" -- and the null /
  ;; thunk / returned-event dispatch.  The model must match production on
  ;; every vector (differential), and both must match the expectation.
  (let ((vectors
          '((;; single resize, drained -> 1 update
             ((:enqueue 0 :resize) (:receive))
             (:returns (:nil) :thunks () :updates 1 :qlen 0))
            (;; terminal burst of two -> TWO updates (production's rule)
             ((:enqueue 0 :resize) (:enqueue 1 :resize) (:receive))
             (:returns (:nil) :thunks () :updates 2 :qlen 0))
            (;; burst of three + one event behind -> only the third resize
             ;; sees <= 1 remaining -> 1 update, event returned
             ((:enqueue 0 :resize) (:enqueue 0 :resize) (:enqueue 0 :resize)
              (:enqueue 1 (:event a)) (:receive))
             (:returns ((:event a)) :thunks () :updates 1 :qlen 0))
            (;; burst of two buried behind two events -> fully coalesced
             ((:enqueue 0 :resize) (:enqueue 0 :resize)
              (:enqueue 1 (:event a)) (:enqueue 1 (:event b))
              (:receive) (:receive))
             (:returns ((:event a) (:event b)) :thunks () :updates 0 :qlen 0))
            (;; a thunk runs inside the consumer's call, then the event returns
             ((:enqueue 2 (:thunk t1)) (:enqueue 1 (:event a)) (:receive))
             (:returns ((:event a)) :thunks (t1) :updates 0 :qlen 0))
            (;; event before a lone resize: first call returns the event
             ;; untouched, the next call processes the resize
             ((:enqueue 0 (:event a)) (:enqueue 0 :resize)
              (:receive) (:receive))
             (:returns ((:event a) :nil) :thunks () :updates 1 :qlen 0))
            (;; an enqueued NIL makes receive-event return nil, consumed
             ((:enqueue 0 :null) (:enqueue 1 (:event a))
              (:receive) (:receive))
             (:returns (:nil (:event a)) :thunks () :updates 0 :qlen 0)))))
    (loop :for (script expected) :in vectors
          :for i :from 0
          :do (let ((real (run-real-script script))
                    (model (run-model-script script)))
                (ok (equal real expected)
                    (format nil "vector ~D: production matches expectation" i))
                (ok (equal model real)
                    (format nil "vector ~D: kernel model matches production" i))))))

(defun random-script (rng)
  "A random enqueue/receive script plus enough trailing receives to fully
drain the queue (each trailing receive returns one returnable item or ends
on the drained queue)."
  (let ((steps '())
        (returnable 0))
    (dotimes (i (rng-range rng 6 24))
      (if (< (rng-below rng 100) 65)
          (let* ((p (rng-below rng 4))
                 (r (rng-below rng 100))
                 (item (cond ((< r 40) (incf returnable) (list :event (list p i)))
                             ((< r 65) (list :thunk (list p i)))
                             ((< r 90) :resize)
                             (t (incf returnable) :null))))
            (push (list :enqueue p item) steps))
          (push '(:receive) steps)))
    (append (nreverse steps)
            (make-list (1+ returnable) :initial-element '(:receive)))))

(defun gen-script ()
  (make-generator :sample #'random-script))

(deftest receive-event-differential
  (ensure-kernel-loaded)
  (for-all ((script (gen-script)))
    (equal (run-real-script script)
           (run-model-script script))))

;;; ------------------------------------------------------------------
;;; 3. Threaded stress: real producer threads through the real queue
;;; ------------------------------------------------------------------

(defparameter *stress-runs-env-var* "LEM_EVENT_QUEUE_STRESS_RUNS"
  "Environment variable overriding the number of threaded stress runs.")

(defun stress-runs ()
  (let ((env (uiop:getenv *stress-runs-env-var*)))
    (or (and env (ignore-errors (parse-integer (string-trim " " env))))
        8)))

(defun make-producer-specs (rng producers events)
  "Per-producer item spec lists: M tagged events -- (:ev p seq) returned
conses or (:thunk p seq) thunks -- with randomized :resize bursts between."
  (loop :for p :below producers
        :collect
        (loop :for seq :below events
              :nconc (let ((tagged (list (if (rng-boolean rng)
                                             (list :ev p seq)
                                             (list :thunk p seq)))))
                       (if (< (rng-below rng 100) 12)
                           (append tagged
                                   (make-list (rng-range rng 1 4)
                                              :initial-element :resize))
                           tagged)))))

(defun run-producer (queue specs arrival-lock arrivals-cell)
  "Producer thread body: send every spec through the REAL send-event."
  (let ((lem-core::*editor-event-queue* queue))
    (loop :for spec :in specs
          :for k :from 0
          :do (lem-core:send-event
               (cond ((eq spec :resize) :resize)
                     ((eq (first spec) :ev) spec)
                     (t
                      ;; thunk: records tag + executing thread AT FUNCALL TIME
                      (let ((p (second spec)) (seq (third spec)))
                        (lambda ()
                          (bt2:with-lock-held (arrival-lock)
                            (push (list :thunk p seq (bt2:current-thread))
                                  (car arrivals-cell))))))))
              ;; interleaving load, not synchronization
              (when (zerop (mod k 37))
                (bt2:thread-yield)))))

(defun run-consumer (queue done arrival-lock arrivals-cell)
  "Consumer thread body: the REAL receive-event loop.  Exits when the done
flag is set and the queue has drained; 60 s wall-clock guard."
  (let ((lem-core::*editor-event-queue* queue)
        (deadline (+ (get-internal-real-time)
                     (* 60 internal-time-units-per-second))))
    (loop
      (when (> (get-internal-real-time) deadline)
        (return (list :timed-out t)))
      (let ((e (lem-core:receive-event 0.05)))
        (cond ((consp e)
               ;; a returned tagged event: (:ev p seq)
               (bt2:with-lock-held (arrival-lock)
                 (push e (car arrivals-cell))))
              ((null e)
               (when (and (plusp (bt2:atomic-integer-value done))
                          (zerop (lem-core:event-queue-length)))
                 (return (list :timed-out nil)))))))))

(defun fifo-ok-p (arrivals producers events)
  "Every producer's tags arrived exactly once, in enqueue order 0..events-1.
ARRIVALS is the consumer-ordered merged log of returned events and executed
thunks."
  (loop :for p :below producers
        :always (equal (loop :for a :in arrivals
                             :when (= (second a) p)
                             :collect (third a))
                       (loop :for i :below events :collect i))))

(defun stress-run-once (rng &key (producers 4) (events 150))
  "One stress run.  Returns a result plist of deterministic observables."
  (call-with-counted-resizes
   (lambda (get-count)
     (let* ((specs (make-producer-specs rng producers events))
            (resizes (1+ (loop :for s :in specs :sum (count :resize s))))
            (queue (lem/common/queue:make-concurrent-queue))
            (done (bt2:make-atomic-integer :value 0))
            (arrival-lock (bt2:make-lock))
            (arrivals-cell (list nil))
            (consumer (bt2:make-thread
                       (lambda ()
                         (run-consumer queue done arrival-lock arrivals-cell))
                       :name "lem-event-queue-stress-consumer"))
            (producer-threads
              (loop :for s :in specs
                    :collect (let ((s s))
                               (bt2:make-thread
                                (lambda ()
                                  (run-producer queue s arrival-lock
                                                arrivals-cell))
                                :name "lem-event-queue-stress-producer")))))
       (mapc #'bt2:join-thread producer-threads)
       ;; Deterministic sentinel: enqueued after every producer has joined,
       ;; this :resize is the queue's LAST entry -- its pop always sees 0
       ;; remaining, so it MUST be processed (updates >= 1).
       (let ((lem-core::*editor-event-queue* queue))
         (lem-core:send-event :resize))
       (bt2:atomic-integer-incf done)
       (let* ((consumer-result (bt2:join-thread consumer))
              (arrivals (reverse (car arrivals-cell)))
              (updates (funcall get-count)))
         (list :timed-out (getf consumer-result :timed-out)
               :conserved (= (length arrivals) (* producers events))
               :fifo-ok (fifo-ok-p arrivals producers events)
               :thunks-on-consumer
               (loop :for a :in arrivals
                     :always (or (not (eq (first a) :thunk))
                                 (eq (fourth a) consumer)))
               :sentinel-processed (<= 1 updates)
               :updates-bounded (<= updates resizes)
               :drained (zerop (lem/common/queue:len queue))))))))

(deftest threaded-event-queue-stress
  (ensure-kernel-loaded)
  (let* ((runs (stress-runs))
         (seed (or *seed* (default-seed)))
         (rng (make-rng seed))
         (timed-out 0)
         (not-conserved 0)
         (fifo-violations 0)
         (thunk-thread-violations 0)
         (sentinel-misses 0)
         (update-overcounts 0)
         (not-drained 0)
         (start-time (get-internal-real-time)))
    (dotimes (i runs)
      (let ((result (stress-run-once rng)))
        (when (getf result :timed-out) (incf timed-out))
        (unless (getf result :conserved) (incf not-conserved))
        (unless (getf result :fifo-ok) (incf fifo-violations))
        (unless (getf result :thunks-on-consumer)
          (incf thunk-thread-violations))
        (unless (getf result :sentinel-processed) (incf sentinel-misses))
        (unless (getf result :updates-bounded) (incf update-overcounts))
        (unless (getf result :drained) (incf not-drained))))
    (let ((elapsed (/ (- (get-internal-real-time) start-time)
                      internal-time-units-per-second)))
      (format t "~&event-queue-stress: ~D runs in ~,1Fs (seed ~D; reproduce with ~A=~D)~%"
              runs elapsed seed *seed-env-var* seed)
      (ok (zerop timed-out)
          (format nil "every consumer drained within the guard (~D timeouts)"
                  timed-out))
      (ok (zerop not-conserved)
          (format nil "every tagged event arrived exactly once (~D violations)"
                  not-conserved))
      (ok (zerop fifo-violations)
          (format nil "per-producer FIFO order across ~D runs (~D violations)"
                  runs fifo-violations))
      (ok (zerop thunk-thread-violations)
          (format nil "thunks executed on the consumer thread only (~D violations)"
                  thunk-thread-violations))
      (ok (zerop sentinel-misses)
          (format nil "the sentinel resize was processed in every run (~D misses)"
                  sentinel-misses))
      (ok (zerop update-overcounts)
          (format nil "updates never exceed enqueued resizes (~D violations)"
                  update-overcounts))
      (ok (zerop not-drained)
          (format nil "the queue drained empty in every run (~D violations)"
                  not-drained)))))

;;; ------------------------------------------------------------------
;;; 4a. Timer model PBT (certified idle-timer arithmetic)
;;; ------------------------------------------------------------------

(defun gen-ktimers ()
  "A generator of non-empty kernel timer lists (id, ms 1..40, repeat, last)."
  (make-generator
   :sample (lambda (rng)
             (loop :for i :below (rng-range rng 1 6)
                   :collect (kcall "MK-KTIMER"
                                   i
                                   (rng-range rng 1 40)
                                   (rng-boolean rng)
                                   (rng-below rng 60))))))

(deftest timer-model-properties
  (ensure-kernel-loaded)
  (for-all ((timers (gen-ktimers))
            (now (gen-integer :min 0 :max 120))
            (t2 (gen-integer :min 0 :max 200)))
    (let ((timing (kcall "KT-NEXT-TIMING" timers now)))
      (and ;; the computed sleep never extends past any timer's due time ...
           (loop :for tm :in timers
                 :always (<= (+ now timing) (kcall "KT-NEXT-TIME" tm)))
           ;; ... nothing fires at the deadline (strict <, ms granularity),
           ;; and the very next ms tick fires
           (null (kcall "KT-FIRED" timers (+ now timing)))
           (consp (kcall "KT-FIRED" timers (+ now timing 1)))
           ;; a wakeup fires something iff the clock is strictly past the
           ;; earliest due time (iff next-timing at the wake time is negative)
           (eq (consp (kcall "KT-FIRED" timers t2))
               (minusp (kcall "KT-NEXT-TIMING" timers t2)))
           ;; partition: every timer is exactly one of fired/remaining
           (= (length timers)
              (+ (length (kcall "KT-FIRED" timers t2))
                 (length (kcall "KT-REMAINING" timers t2))))
           (<= (length (kcall "KT-PROCESSED" timers t2))
               (length (kcall "KT-FIRED" timers t2)))))))

;;; ------------------------------------------------------------------
;;; 4b. Simulated-clock differential: production timers vs. the kernel
;;; ------------------------------------------------------------------

(defun prod-ids (timers alist)
  "The spec ids of the production TIMERS, via the id->timer ALIST."
  (loop :for (id . timer) :in alist
        :when (member timer timers)
        :collect id))

(defun model-ids (model-timers)
  (mapcar (lambda (tm) (kcall "KTIMER-ID" tm)) model-timers))

(defun last-times-match-p (model-timers alist)
  "Production timer-last-time equals the kernel's ktimer-last, per id."
  (loop :for tm :in model-timers
        :for prod := (cdr (assoc (kcall "KTIMER-ID" tm) alist))
        :always (equal (lem/common/timer::timer-last-time prod)
                       (kcall "KTIMER-LAST" tm))))

(defun run-idle-period (rng specs survivors alist fired-cell)
  "One production idle period (caller wraps in with-idle-timers, whose
start-idle-timers has just refreshed every survivor's last-time to the
current virtual clock).  Steps the clock, comparing production's sleep and
firing decisions against the kernel each tick.  Returns (list ok survivors
reason) -- a single value, because with-idle-timers' prog1 drops secondary
values."
  (let* ((now lem-tests/timer::*current-time*)
         (model (loop :for (id ms repeat) :in specs
                      :when (member id survivors)
                      :collect (kcall "MK-KTIMER" id ms repeat now)))
         (model-processed '()))
    (dotimes (i (rng-range rng 3 12))
      (incf lem-tests/timer::*current-time* (rng-below rng 25))
      (let ((tick lem-tests/timer::*current-time*))
        ;; the sleep computation production's read loop uses
        (unless (equal (lem/common/timer:get-next-timer-timing-ms)
                       (kcall "KT-NEXT-TIMING" model tick))
          (return-from run-idle-period (list nil nil :next-timing)))
        ;; fire, comparing the decision and the fired id set
        (setf (car fired-cell) nil)
        (let* ((prod-fired-p (lem/common/timer:update-idle-timers))
               (prod-fired (sort (copy-list (car fired-cell)) #'<))
               (model-fired (kcall "KT-FIRED" model tick))
               (fired-ids (sort (model-ids model-fired) #'<))
               (processed-ids (sort (model-ids model-processed) #'<))
               ;; The DOCUMENTED PRODUCTION DOUBLE-FIRE (see the book header
               ;; and `timer-double-fire-reproducer' below): when the last
               ;; due timer in production's internal list order is a repeat
               ;; timer and the processed list is non-empty,
               ;; update-idle-timers' nconc splices the processed list onto
               ;; the very list mapc is about to fire, re-firing every
               ;; already-processed timer.  Production's internal order is
               ;; unobservable (set-difference scrambles it), so under this
               ;; envelope condition both the clean and the double-fire
               ;; outcomes are legitimate production behavior; the list
               ;; bookkeeping after the tick is identical either way and
               ;; stays exactly asserted below.
               (double-fire-possible
                 (and (consp model-processed)
                      (loop :for tm :in model-fired
                            :thereis (third (find (kcall "KTIMER-ID" tm)
                                                  specs :key #'first))))))
          (unless (and (eq (and prod-fired-p t) (consp model-fired))
                       (or (equal prod-fired fired-ids)
                           (and double-fire-possible
                                (equal prod-fired
                                       (sort (append fired-ids processed-ids)
                                             #'<)))))
            (return-from run-idle-period (list nil nil :fired)))
          (setf model-processed
                (append model-processed (kcall "KT-PROCESSED" model tick)))
          (setf model (kcall "KT-REMAINING" model tick))
          ;; production's list bookkeeping, as id sets (order caveat) +
          ;; last-time per id
          (unless (and (equal (sort (prod-ids lem/common/timer::*idle-timer-list*
                                              alist)
                                    #'<)
                              (sort (model-ids model) #'<))
                       (equal (sort (prod-ids lem/common/timer::*processed-idle-timer-list*
                                              alist)
                                    #'<)
                              (sort (model-ids model-processed) #'<))
                       (last-times-match-p model alist)
                       (last-times-match-p model-processed alist))
            (return-from run-idle-period (list nil nil :bookkeeping))))))
    (list t (append (model-ids model) (model-ids model-processed)) nil)))

(defun run-one-timer-differential (rng)
  "One random schedule across 1-3 idle periods.  Returns NIL on success or a
divergence keyword."
  (let* ((n (rng-range rng 1 5))
         (specs (loop :for i :below n
                      :collect (list i (rng-range rng 1 40) (rng-boolean rng))))
         (fired-cell (list nil)))
    (lem/common/timer:with-timer-manager
        (make-instance 'lem-tests/timer::testing-timer-manager)
      (let ((lem-tests/timer::*current-time* 0)
            (lem/common/timer::*idle-timer-list* '())
            (lem/common/timer::*processed-idle-timer-list* '())
            (alist '()))
        (dolist (spec specs)
          (destructuring-bind (id ms repeat) spec
            (let ((timer (lem/common/timer:make-idle-timer
                          (let ((id id))
                            (lambda () (push id (car fired-cell))))
                          :name (princ-to-string id))))
              (push (cons id timer) alist)
              (lem/common/timer:start-timer timer ms :repeat repeat))))
        (let ((survivors (mapcar #'first specs)))
          (dotimes (period (rng-range rng 1 3))
            (destructuring-bind (ok new-survivors reason)
                (lem/common/timer:with-idle-timers ()
                  (run-idle-period rng specs survivors alist fired-cell))
              (unless ok
                (return-from run-one-timer-differential reason))
              (setf survivors new-survivors)))
          nil)))))

(deftest timer-double-fire-reproducer
  ;; PRODUCTION BUG FOUND BY THIS ITEM (documented, not fixed here -- the
  ;; VK-3/VK-6 precedent; this test is the record).  In update-idle-timers
  ;; (src/common/timer.lisp), UPDATING-TIMERS / UPDATING-IDLE-TIMERS are
  ;; remove-if-not results that MAY SHARE list structure with their input
  ;; (CLHS-permitted; SBCL shares the maximal tail -- verified on SBCL
  ;; 2.5.10).  The subsequent
  ;;   (setf *processed-idle-timer-list*
  ;;         (nconc updating-idle-timers *processed-idle-timer-list*))
  ;; therefore splices the processed list onto UPDATING-TIMERS' final cons
  ;; whenever the last due timer (in *idle-timer-list* order) is a repeat
  ;; timer -- and the later (mapc #'call-timer-function updating-timers)
  ;; walks the splice, RE-FIRING every already-processed repeat timer in the
  ;; same idle period.  The list bookkeeping ends correct; only the extra
  ;; funcalls are wrong.  Deterministic reproducer: A (10ms, repeat) fires
  ;; and is parked; when B (20ms, repeat) fires later, A fires AGAIN.
  (let ((fired '()))
    (lem/common/timer:with-timer-manager
        (make-instance 'lem-tests/timer::testing-timer-manager)
      (let ((lem-tests/timer::*current-time* 0)
            (lem/common/timer::*idle-timer-list* '())
            (lem/common/timer::*processed-idle-timer-list* '()))
        (lem/common/timer:start-timer
         (lem/common/timer:make-idle-timer (lambda () (push :a fired)) :name "a")
         10 :repeat t)
        (lem/common/timer:start-timer
         (lem/common/timer:make-idle-timer (lambda () (push :b fired)) :name "b")
         20 :repeat t)
        (lem/common/timer:with-idle-timers ()
          (setf lem-tests/timer::*current-time* 15)
          (lem/common/timer:update-idle-timers)
          (ok (equal fired '(:a)) "A fires alone at t=15 and is parked")
          (setf lem-tests/timer::*current-time* 25)
          (setf fired '())
          (lem/common/timer:update-idle-timers)
          (ok (equal (sort (copy-list fired) #'string< :key #'symbol-name)
                     '(:a :b))
              "BUG PINNED: B's firing at t=25 re-fires the already-processed A")
          ;; the bookkeeping is nevertheless correct: nothing left idle,
          ;; both repeat timers parked exactly once
          (ok (null lem/common/timer::*idle-timer-list*)
              "idle list drained")
          (ok (= 2 (length lem/common/timer::*processed-idle-timer-list*))
              "both timers parked exactly once"))))))

(deftest timer-model-vs-production
  (ensure-kernel-loaded)
  (let* ((seed (or *seed* (default-seed)))
         (rng (make-rng seed))
         (failures '()))
    (dotimes (i 60)
      (let ((reason (run-one-timer-differential rng)))
        (when reason (push reason failures))))
    (ok (null failures)
        (format nil "timer differential, 60 schedules (seed ~D; reproduce with ~A=~D): ~A"
                seed *seed-env-var* seed
                (if failures failures "no divergence")))))
