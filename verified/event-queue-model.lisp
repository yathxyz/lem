;;;; verified/event-queue-model.lisp -- Event queue + idle-timer model (SPEC-VK VK-9).
;;;;
;;;; One source of truth (SPEC-VK Constraint 2): this same file is certified by
;;;; ACL2 (scripts/run-proofs.sh) AND loaded verbatim into the Lem SBCL image
;;;; through verified/shim.lisp.
;;;;
;;;; PRODUCTION SOURCES TRANSCRIBED (production is the spec):
;;;;
;;;;   * src/common/queue.lisp -- `concurrent-queue': a lock + condition
;;;;     variable around a plain FIFO list queue (enqueue at the tail,
;;;;     dequeue at the head).  Modeled as the entry list `queue' below.
;;;;   * src/event-queue.lisp -- `send-event' (= enqueue) and `receive-event',
;;;;     whose dequeue loop is transcribed EXACTLY:
;;;;
;;;;       (loop
;;;;         (let ((e (dequeue *editor-event-queue*
;;;;                           :timeout timeout :timeout-value :timeout)))
;;;;           (cond ((null e) (return nil))
;;;;                 ((eql e :timeout) (assert timeout) (return nil))
;;;;                 ((eql e :resize)
;;;;                  (when (>= 1 (event-queue-length))   ; <= 1 events REMAIN
;;;;                    (update-on-display-resized)))     ;    after the pop
;;;;                 ((or (functionp e) (symbolp e)) (funcall e))
;;;;                 (t (return e)))))
;;;;
;;;;   * src/lem.lisp `send-timer-notification' (lem-timer-manager): the timer
;;;;     thread injects its work as a THUNK through send-event -- in the model
;;;;     an (:enqueue timer-producer (:thunk tag)) action; thunk execution then
;;;;     happens inside the consumer's dequeue loop (`funcall' above), never on
;;;;     the producer side.  Producers = {input thread, timer thread,
;;;;     background jobs}: the model's producer ids.
;;;;   * src/common/timer.lisp `get-next-timer-timing-ms' /
;;;;     `update-idle-timers' -- the idle-timer arithmetic, ported as pure
;;;;     functions over an explicit virtual clock (see the TIMER section).
;;;;
;;;; MODEL (queue side).  An entry is (producer item); item is
;;;;   :resize      -- the literal :resize keyword event,
;;;;   (:thunk tag) -- a functionp/symbolp event (funcalled by the consumer),
;;;;   (:event tag) -- any other object (returned to receive-event's caller),
;;;;   :null        -- an enqueued NIL (receive-event returns nil, entry
;;;;                   consumed).
;;;; NOT modeled: an enqueued :timeout keyword.  Production's :timeout is
;;;; dequeue's timeout-value, not a queue element; a :timeout literally sent
;;;; through send-event would trip receive-event's (assert timeout) under a
;;;; nil timeout.  Recorded, excluded from the item alphabet.
;;;;
;;;; STEP GRANULARITY.  One :dequeue step = one iteration of receive-event's
;;;; loop = one pop under the queue lock (production holds the lock per
;;;; dequeue only, so producer enqueues interleave freely BETWEEN iterations
;;;; -- exactly the model's traces, where (:enqueue p item) actions appear at
;;;; any point between (:dequeue) actions).  A receive-event CALL is a maximal
;;;; run of :dequeue steps ending at a returned event / :null / empty-queue
;;;; timeout; the call boundary carries no queue state, so all theorems
;;;; quantify over dequeue steps and cover every call segmentation.
;;;;
;;;; STATE: (queue enq-log deq-log updates thunks)
;;;;   queue    -- current queue contents, head first
;;;;   enq-log  -- every entry ever enqueued, in enqueue order (ghost)
;;;;   deq-log  -- every entry ever dequeued, in dequeue order (ghost)
;;;;   updates  -- count of update-on-display-resized calls (observable)
;;;;   thunks   -- tags of executed thunks, in execution order (observable)
;;;;
;;;; THEOREMS (all traces, structural induction):
;;;;   1. NO EVENT LOSS -- wf-eq (an inductive invariant, wf-eq-of-reachable)
;;;;      pins enq-log = deq-log ++ queue: dequeues are a PREFIX of enqueues
;;;;      (dequeues-are-a-prefix-of-enqueues) -- nothing reordered, duplicated
;;;;      or invented -- and once the queue drains, deq-log = enq-log
;;;;      (drained-no-loss): every enqueued entry is dequeued EXACTLY ONCE, in
;;;;      global FIFO order.  Note the coalescing rule drops the resize
;;;;      EFFECT, never the event: coalesced resizes are still dequeued, so
;;;;      the log equality is exact, not modulo-coalescing.
;;;;   2. PER-PRODUCER FIFO -- per-producer-fifo: the subsequence of p's
;;;;      dequeued entries is a prefix of the subsequence p enqueued (equal
;;;;      after a drain, per-producer-fifo-drained); two events from one
;;;;      producer always dequeue in enqueue order.  (Production's queue is a
;;;;      single global FIFO, so this is the filter of obligation 1.)
;;;;   3. COALESCING, production's EXACT rule (resize-step-exact): a dequeued
;;;;      :resize triggers update-on-display-resized iff AT MOST ONE event
;;;;      remains in the queue at that moment -- (>= 1 (event-queue-length))
;;;;      after the pop.  Consequences over a drain (drain-updates-exact via
;;;;      eq-resize-tail-count): resizes with >= 2 events still queued behind
;;;;      them -- interleaved enqueues included -- are coalesced silently
;;;;      (events-behind-suppress-coalescing), and a TERMINAL burst of n
;;;;      consecutive resizes yields (min n 2) updates
;;;;      (terminal-burst-updates).
;;;;      DEVIATION RECORD (SPEC-VK Constraint 5): the spec's "a burst of N
;;;;      consecutive :resize events yields exactly one processed resize" is
;;;;      REFUTED by production for every N >= 2: the last TWO resizes of a
;;;;      terminal burst each see <= 1 events remaining, so the burst yields
;;;;      exactly TWO update calls (ground witness coalescing-ground-witness;
;;;;      pinned against live production by tests/pbt/event-queue-stress.lisp
;;;;      fixed vector [:resize :resize] -> 2). A burst buried behind >= 2
;;;;      queued events yields ZERO.  Production is the spec: the theorems
;;;;      state the exact rule, and no "exactly one" claim is made.
;;;;   4. THUNKS RUN ONLY ON THE CONSUMER -- thunk execution (and resize
;;;;      processing) is an effect of :dequeue steps exclusively:
;;;;      non-dequeue-steps-execute-nothing (an :enqueue never funcalls --
;;;;      send-event only pushes), and thunks-run-in-dequeue-order: the
;;;;      executed-thunk log equals the thunk subsequence of deq-log.  That
;;;;      dequeue steps happen only on the editor thread is production's
;;;;      single-consumer discipline (receive-event is called from the editor
;;;;      command loop only) -- TRUST-BASE RESIDUE outside the model, pinned
;;;;      by the threaded stress suite, which asserts every thunk executes on
;;;;      the consumer thread.
;;;;
;;;; ===========================================================================
;;;; TIMER section: idle-timer arithmetic over a virtual clock
;;;; ===========================================================================
;;;;
;;;; Clocks are NATURALS in MILLISECONDS (production's get-microsecond-time,
;;;; despite its name, returns internal-real-time scaled to ms).  A timer is
;;;; (id ms repeat last): `ms' the period, `last' the last-idle reference
;;;; time; due-time = last + ms; production compares with STRICT < (a timer
;;;; whose due-time equals the current tick is NOT yet due -- update-idle-timers'
;;;; (< (timer-next-time timer) tick-time)).  Transcribed:
;;;;   kt-next-time    -- timer-next-time (last + ms)
;;;;   kt-next-timing  -- get-next-timer-timing-ms: nil when no timers, else
;;;;                      (min over next-times) - now (negative when overdue)
;;;;   kt-fired        -- update-idle-timers' updating-timers (next-time < now),
;;;;                      in list order (remove-if-not preserves order; mapc
;;;;                      call-timer-function fires in that order)
;;;;   kt-remaining    -- the timers kept in *idle-timer-list* (both
;;;;                      set-difference removals = the not-due filter)
;;;;   kt-processed    -- fired AND repeat: parked in *processed-idle-timer-list*
;;;;                      with last-time UNCHANGED (production refreshes
;;;;                      last-time only at the next idle entry,
;;;;                      start-idle-timers) -- so a repeat idle timer fires at
;;;;                      most once per idle period
;;;;   kt-expired      -- fired AND not repeat: expired + deleted (production
;;;;                      also sets their last-time to tick -- a dead store on
;;;;                      a removed timer, transcribed as removal)
;;;;
;;;; THEOREMS (ms granularity stated precisely):
;;;;   * kt-min-next-lower-bound + kt-never-sleeps-past-due: the computed
;;;;     sleep never extends past ANY timer's due time, and no timer fires at
;;;;     any wake time <= now + next-timing.  Sleeping exactly next-timing ms
;;;;     therefore cannot skip a firing.
;;;;   * kt-wakeup-fires-iff-something-overdue: a wakeup fires some timer IFF
;;;;     the clock is STRICTLY past the earliest due-time (iff next-timing
;;;;     < 0 at the wake time) -- no wakeup fires when nothing is due.
;;;;   * kt-deadline-wakeup-fires-nothing / kt-first-tick-after-deadline-fires:
;;;;     the 1 ms boundary, exactly: waking AT the deadline fires nothing
;;;;     (strict <; production's read-event-internal takes its (<= ms 0)
;;;;     branch, calls update-idle-timers vacuously and loops -- a busy window
;;;;     bounded by the 1 ms clock granularity), and the very next tick fires.
;;;;   * kt-fired-remaining-partition / kt-fired-splits-into-expired-and-processed:
;;;;     every timer is exactly one of fired/remaining, every fired timer
;;;;     exactly one of expired/processed -- nothing lost by the two
;;;;     set-differences.
;;;;
;;;; ORDER CAVEAT (documented, differential-tested as sets): production prunes
;;;; *idle-timer-list* with SET-DIFFERENCE, whose result order is unspecified;
;;;; kt-remaining keeps input order.  The divergence is unobservable except
;;;; through the fire order of a LATER tick with >= 2 simultaneously-due
;;;; timers; the differential suite therefore compares fired/remaining/
;;;; processed as id-sets per tick, plus (ms, last) per id.
;;;;
;;;; PRODUCTION BUG FOUND BY THIS ITEM (documented, not fixed here -- the
;;;; VK-3/VK-6 charter precedent; reproducer pinned in
;;;; tests/pbt/event-queue-stress.lisp `timer-double-fire-reproducer').
;;;; update-idle-timers' UPDATING-TIMERS / UPDATING-IDLE-TIMERS are
;;;; remove-if-not results, which MAY SHARE structure with their input
;;;; (CLHS-permitted; SBCL shares the maximal tail).  The
;;;;   (setf *processed-idle-timer-list*
;;;;         (nconc updating-idle-timers *processed-idle-timer-list*))
;;;; runs BEFORE (mapc #'call-timer-function updating-timers), so whenever
;;;; the last due timer in *idle-timer-list* order is a repeat timer and the
;;;; processed list is non-empty, the nconc splices the processed list onto
;;;; UPDATING-TIMERS' final cons and mapc RE-FIRES every already-processed
;;;; repeat timer in the same idle period (extra funcalls only; the list
;;;; bookkeeping ends correct).  The kernel model states the intended,
;;;; implementation-independent semantics -- kt-fired fires each due timer
;;;; exactly once per tick, a repeat timer at most once per idle period --
;;;; and the differential accepts production's double-fire outcome exactly
;;;; under its envelope condition (some fired timer repeat AND processed
;;;; non-empty), the precise trigger being unobservable from outside.
;;;;
;;;; EXEC PATH (functions the in-image suite tests/pbt/event-queue-stress.lisp
;;;; calls): eq-init, eq-step, eq-run, eq-drain, wf-eq, eqs-queue, eqs-enq-log,
;;;; eqs-deq-log, eqs-updates, eqs-thunks, mk-entry, entry-producer,
;;;; entry-item, eq-by-producer, eq-thunk-tags, eqm-prefixp,
;;;; eq-resize-tail-count, mk-ktimer, ktimer-id, ktimer-last, kt-next-time,
;;;; kt-next-timing, kt-fired, kt-remaining, kt-processed.  All use only CL
;;;; homonyms plus the already whitelisted natp/len -- NO shim whitelist
;;;; growth for VK-9.  eq-resize-burst is proof-support only (its statement
;;;; uses nfix/min in defthms; the defun itself avoids zp so it stays
;;;; CL-loadable).  ACL2 strings and characters are never used.

(in-package "ACL2")

;; Lemma library for arithmetic (proof-only: local, nothing exec-reachable).
(local (include-book "arithmetic/top-with-meta" :dir :system))

;;; ===========================================================================
;;; List lemmas (local proof support)
;;; ===========================================================================

(local
 (defthm append-assoc
   (equal (append (append a b) c)
          (append a (append b c)))))

(local
 (defthm true-listp-of-append
   (implies (true-listp b)
            (true-listp (append a b)))))

(local
 (defthm append-nil-right
   (implies (true-listp a)
            (equal (append a nil) a))))

(local
 (defthm len-of-append
   (equal (len (append a b))
          (+ (len a) (len b)))))

;;; ===========================================================================
;;; Queue entries
;;; ===========================================================================

(defun mk-entry (producer item)
  (list producer item))

(defun entry-producer (e) (nth 0 e))
(defun entry-item (e) (nth 1 e))

(defun eq-resize-entry-p (e)
  (eq (entry-item e) :resize))

(defun eq-thunk-entry-p (e)
  (and (consp (entry-item e))
       (eq (car (entry-item e)) :thunk)))

(defun eq-thunk-tag (e)
  (cadr (entry-item e)))

;; The thunk subsequence of an entry list, as executed-tag order.
(defun eq-thunk-tags (entries)
  (cond ((atom entries) nil)
        ((eq-thunk-entry-p (car entries))
         (cons (eq-thunk-tag (car entries))
               (eq-thunk-tags (cdr entries))))
        (t (eq-thunk-tags (cdr entries)))))

(local
 (defthm true-listp-of-eq-thunk-tags
   (true-listp (eq-thunk-tags entries))))

(local
 (defthm eq-thunk-tags-of-append
   (equal (eq-thunk-tags (append a b))
          (append (eq-thunk-tags a) (eq-thunk-tags b)))))

;;; ===========================================================================
;;; State, actions, the step function (TOTAL over (state, action))
;;; ===========================================================================

(defun mk-eqs (queue enq-log deq-log updates thunks)
  (list queue enq-log deq-log updates thunks))

(defun eqs-queue (st) (nth 0 st))
(defun eqs-enq-log (st) (nth 1 st))
(defun eqs-deq-log (st) (nth 2 st))
(defun eqs-updates (st) (nth 3 st))
(defun eqs-thunks (st) (nth 4 st))

(defun eq-init ()
  (mk-eqs nil nil nil 0 nil))

;; An action is (:enqueue producer item) -- send-event on producer's thread --
;; or (:dequeue) -- one iteration of receive-event's loop on the consumer.
(defun eq-act-name (act) (if (consp act) (car act) act))

(defun eq-step (st act)
  (cond
    ;; send-event: enqueue at the tail.  No funcall, no update -- the
    ;; producer side only pushes.
    ((eq (eq-act-name act) :enqueue)
     (let ((entry (mk-entry (cadr act) (caddr act))))
       (mk-eqs (append (eqs-queue st) (list entry))
               (append (eqs-enq-log st) (list entry))
               (eqs-deq-log st)
               (eqs-updates st)
               (eqs-thunks st))))
    ;; One receive-event loop iteration: pop the head (empty queue = the
    ;; timeout/condition-wait branch, a no-op on queue state), then
    ;; production's cond: :resize processes iff <= 1 events REMAIN after the
    ;; pop ((>= 1 (event-queue-length))); a thunk is funcalled; :null and
    ;; plain events return to the caller (consumed either way).
    ((eq (eq-act-name act) :dequeue)
     (if (atom (eqs-queue st))
         st
         (let ((e (car (eqs-queue st)))
               (rest (cdr (eqs-queue st))))
           (mk-eqs rest
                   (eqs-enq-log st)
                   (append (eqs-deq-log st) (list e))
                   (if (and (eq-resize-entry-p e)
                            (<= (len rest) 1))
                       (+ 1 (eqs-updates st))
                       (eqs-updates st))
                   (if (eq-thunk-entry-p e)
                       (append (eqs-thunks st) (list (eq-thunk-tag e)))
                       (eqs-thunks st))))))
    (t st)))

;; Run an arbitrary action trace.  Reachable state := (eq-run (eq-init) acts)
;; for SOME acts -- quantifying over ACTS quantifies over every interleaving
;; of producer enqueues and consumer dequeues.
(defun eq-run (st acts)
  (if (atom acts)
      st
      (eq-run (eq-step st (car acts)) (cdr acts))))

;;; ===========================================================================
;;; The inductive invariant: enq-log = deq-log ++ queue, thunks = thunk(deq)
;;; ===========================================================================

(defun wf-eq (st)
  (and (true-listp (eqs-queue st))
       (true-listp (eqs-enq-log st))
       (true-listp (eqs-deq-log st))
       (natp (eqs-updates st))
       (true-listp (eqs-thunks st))
       ;; every enqueued entry is either already dequeued (in order) or still
       ;; queued (in order) -- and nothing else exists
       (equal (eqs-enq-log st)
              (append (eqs-deq-log st) (eqs-queue st)))
       ;; the executed thunks are exactly the thunk subsequence of deq-log
       (equal (eqs-thunks st)
              (eq-thunk-tags (eqs-deq-log st)))))

(defthm wf-eq-of-eq-init
  (wf-eq (eq-init)))

;; Proof note: the wf-eq hypothesis orients enq-log = (append deq-log queue)
;; by term order (the append form rewrites TO the accessor), so the enabled
;; left-to-right append-assoc can never rebuild the (append deq-log queue)
;; redex in the conclusion.  The two :use instances provide exactly the
;; re-associations the enqueue and dequeue cases need, with the rewrite rule
;; disabled so the instances survive simplification.
(defthm wf-eq-of-eq-step
  (implies (wf-eq st)
           (wf-eq (eq-step st act)))
  :hints (("Goal"
           :use ((:instance append-assoc
                            (a (eqs-deq-log st))
                            (b (eqs-queue st))
                            (c (list (mk-entry (cadr act) (caddr act)))))
                 (:instance append-assoc
                            (a (eqs-deq-log st))
                            (b (list (car (eqs-queue st))))
                            (c (cdr (eqs-queue st)))))
           :in-theory (disable append-assoc))))

(defthm wf-eq-of-eq-run
  (implies (wf-eq st)
           (wf-eq (eq-run st acts)))
  :hints (("Goal" :in-theory (disable wf-eq eq-step))))

(defthm wf-eq-of-reachable
  (wf-eq (eq-run (eq-init) acts))
  :hints (("Goal" :in-theory (disable wf-eq eq-step eq-init eq-run))))

;;; ===========================================================================
;;; VK-9 obligation 1 (no event loss)
;;; ===========================================================================

(defthm no-loss-log-decomposition
  (equal (eqs-enq-log (eq-run (eq-init) acts))
         (append (eqs-deq-log (eq-run (eq-init) acts))
                 (eqs-queue (eq-run (eq-init) acts))))
  :hints (("Goal" :use (:instance wf-eq-of-reachable)
           :in-theory (disable wf-eq-of-reachable eq-run eq-init))))

(defun eqm-prefixp (a b)
  (if (atom a)
      t
      (and (consp b)
           (equal (car a) (car b))
           (eqm-prefixp (cdr a) (cdr b)))))

(local
 (defthm eqm-prefixp-of-append-self
   (eqm-prefixp a (append a c))))

;; Nothing is reordered, duplicated or invented: at every reachable state the
;; dequeue log is a prefix of the enqueue log.
(defthm dequeues-are-a-prefix-of-enqueues
  (eqm-prefixp (eqs-deq-log (eq-run (eq-init) acts))
               (eqs-enq-log (eq-run (eq-init) acts)))
  :hints (("Goal" :use (:instance no-loss-log-decomposition)
           :in-theory (disable no-loss-log-decomposition eq-run eq-init))))

;; Once the queue drains, every enqueued entry has been dequeued EXACTLY once,
;; in enqueue order.
(defthm drained-no-loss
  (implies (atom (eqs-queue (eq-run (eq-init) acts)))
           (equal (eqs-deq-log (eq-run (eq-init) acts))
                  (eqs-enq-log (eq-run (eq-init) acts))))
  :hints (("Goal" :use (:instance wf-eq-of-reachable)
           :in-theory (disable wf-eq-of-reachable eq-run eq-init))))

;;; ===========================================================================
;;; VK-9 obligation 2 (per-producer FIFO)
;;; ===========================================================================

(defun eq-by-producer (p entries)
  (cond ((atom entries) nil)
        ((equal (entry-producer (car entries)) p)
         (cons (car entries) (eq-by-producer p (cdr entries))))
        (t (eq-by-producer p (cdr entries)))))

(local
 (defthm eq-by-producer-of-append
   (equal (eq-by-producer p (append a b))
          (append (eq-by-producer p a) (eq-by-producer p b)))))

;; Two events from the same producer dequeue in enqueue order: p's dequeued
;; subsequence is always a prefix of p's enqueued subsequence.
(defthm per-producer-fifo
  (eqm-prefixp (eq-by-producer p (eqs-deq-log (eq-run (eq-init) acts)))
               (eq-by-producer p (eqs-enq-log (eq-run (eq-init) acts))))
  :hints (("Goal" :use (:instance no-loss-log-decomposition)
           :in-theory (disable no-loss-log-decomposition eq-run eq-init))))

(defthm per-producer-fifo-drained
  (implies (atom (eqs-queue (eq-run (eq-init) acts)))
           (equal (eq-by-producer p (eqs-deq-log (eq-run (eq-init) acts)))
                  (eq-by-producer p (eqs-enq-log (eq-run (eq-init) acts)))))
  :hints (("Goal" :use (:instance drained-no-loss)
           :in-theory (disable drained-no-loss eq-run eq-init))))

;;; ===========================================================================
;;; VK-9 obligation 3 (resize coalescing -- production's exact rule)
;;; ===========================================================================

;; Step-level transcription pin: a dequeued :resize calls
;; update-on-display-resized iff at most ONE event remains after the pop --
;; production's (when (>= 1 (event-queue-length)) ...) -- and nothing else
;; ever bumps the update count.
(defthm resize-step-exact
  (implies (consp (eqs-queue st))
           (equal (eqs-updates (eq-step st '(:dequeue)))
                  (if (and (eq-resize-entry-p (car (eqs-queue st)))
                           (<= (len (cdr (eqs-queue st))) 1))
                      (+ 1 (eqs-updates st))
                      (eqs-updates st)))))

;; A full drain (consumer runs with no interleaved enqueues).  Terminates by
;; the queue length.
(defun eq-drain (st)
  (declare (xargs :measure (len (eqs-queue st))))
  (if (atom (eqs-queue st))
      st
      (eq-drain (eq-step st '(:dequeue)))))

;; The resizes a drain of QUEUE will process: those with <= 1 entries behind
;; them, i.e. the resizes among the last two queued entries.
(defun eq-resize-tail-count (queue)
  (if (atom queue)
      0
      (+ (if (and (eq-resize-entry-p (car queue))
                  (<= (len (cdr queue)) 1))
             1
             0)
         (eq-resize-tail-count (cdr queue)))))

(defthm drain-empties-queue
  (atom (eqs-queue (eq-drain st))))

(defthm drain-updates-exact
  (implies (natp (eqs-updates st))
           (equal (eqs-updates (eq-drain st))
                  (+ (eqs-updates st)
                     (eq-resize-tail-count (eqs-queue st)))))
  :hints (("Goal" :induct (eq-drain st))))

(defthm drain-dequeues-everything
  (implies (and (true-listp (eqs-queue st))
                (true-listp (eqs-deq-log st)))
           (equal (eqs-deq-log (eq-drain st))
                  (append (eqs-deq-log st) (eqs-queue st))))
  :hints (("Goal" :induct (eq-drain st))))

;; Coalescing, the suppression half: a resize with >= 2 events still queued
;; behind it -- whatever they are, later enqueues included -- is dequeued
;; silently.  ANY front segment of the queue coalesces to zero updates when
;; >= 2 entries sit behind it.
(defthm events-behind-suppress-coalescing
  (implies (<= 2 (len rest))
           (equal (eq-resize-tail-count (append front rest))
                  (eq-resize-tail-count rest))))

;; A terminal burst of n consecutive resizes (nothing behind them).
;; Proof-support constructor (kept zp-free so it stays CL-loadable).
(defun eq-resize-burst (p n)
  (declare (xargs :measure (nfix n)))
  (if (and (integerp n) (< 0 n))
      (cons (mk-entry p :resize) (eq-resize-burst p (- n 1)))
      nil))

(local
 (defthm len-of-eq-resize-burst
   (equal (len (eq-resize-burst p n))
          (nfix n))))

;; DEVIATION RECORD (Constraint 5, see header): production processes the last
;; TWO resizes of a terminal burst -- (min n 2) updates, not the spec's
;; "exactly one" -- because each of the last two pops leaves <= 1 events.
(defthm terminal-burst-updates
  (equal (eq-resize-tail-count (eq-resize-burst p n))
         (min (nfix n) 2)))

;; Ground witness (non-vacuity): concrete traces exhibiting the 1 / 2 / 0
;; update counts.  Certifies by evaluation, so an edit to the step function
;; that changes the coalescing rule fails right here.
(defthm coalescing-ground-witness
  (and ;; single resize -> 1 update
       (equal (eqs-updates
               (eq-drain (eq-run (eq-init) '((:enqueue 1 :resize)))))
              1)
       ;; terminal burst of two -> 2 updates (the refuted "exactly one")
       (equal (eqs-updates
               (eq-drain (eq-run (eq-init)
                                 '((:enqueue 1 :resize)
                                   (:enqueue 2 :resize)))))
              2)
       ;; burst of three with one event behind -> the third resize alone
       ;; sees <= 1 remaining -> 1 update
       (equal (eqs-updates
               (eq-drain (eq-run (eq-init)
                                 '((:enqueue 1 :resize)
                                   (:enqueue 1 :resize)
                                   (:enqueue 1 :resize)
                                   (:enqueue 2 (:event a))))))
              1)
       ;; burst of two buried behind two events -> fully coalesced, 0 updates
       (equal (eqs-updates
               (eq-drain (eq-run (eq-init)
                                 '((:enqueue 1 :resize)
                                   (:enqueue 1 :resize)
                                   (:enqueue 2 (:event a))
                                   (:enqueue 2 (:event b))))))
              0))
  :rule-classes nil)

;;; ===========================================================================
;;; VK-9 obligation 4 (thunks execute only in consumer steps)
;;; ===========================================================================

;; Only a :dequeue step can execute a thunk or process a resize: an :enqueue
;; (send-event) never funcalls anything and never updates the display.
(defthm non-dequeue-steps-execute-nothing
  (implies (not (eq (eq-act-name act) :dequeue))
           (and (equal (eqs-thunks (eq-step st act)) (eqs-thunks st))
                (equal (eqs-updates (eq-step st act)) (eqs-updates st)))))

;; The executed-thunk log is exactly the thunk subsequence of the dequeue
;; log: every thunk runs exactly once, at its dequeue, in dequeue order.
(defthm thunks-run-in-dequeue-order
  (equal (eqs-thunks (eq-run (eq-init) acts))
         (eq-thunk-tags (eqs-deq-log (eq-run (eq-init) acts))))
  :hints (("Goal" :use (:instance wf-eq-of-reachable)
           :in-theory (disable wf-eq-of-reachable eq-run eq-init))))

;;; ===========================================================================
;;; TIMER section: idle-timer arithmetic (src/common/timer.lisp)
;;; ===========================================================================

(defun mk-ktimer (id ms repeat last)
  (list id ms repeat last))

(defun ktimer-id (tm) (nth 0 tm))
(defun ktimer-ms (tm) (nth 1 tm))
(defun ktimer-repeat (tm) (nth 2 tm))
(defun ktimer-last (tm) (nth 3 tm))

;; timer-next-time: (+ (timer-last-time timer) (timer-ms timer)).
(defun kt-next-time (tm)
  (+ (ktimer-last tm) (ktimer-ms tm)))

;; update-idle-timers' due test, STRICT: (< (timer-next-time timer) tick-time).
(defun kt-due-p (tm now)
  (< (kt-next-time tm) now))

;; The (loop :minimize (timer-next-time timer)) of get-next-timer-timing-ms.
(defun kt-min-next (timers)
  (cond ((atom timers) 0)
        ((atom (cdr timers)) (kt-next-time (car timers)))
        (t (min (kt-next-time (car timers))
                (kt-min-next (cdr timers))))))

;; get-next-timer-timing-ms: nil when no idle timers, else min-next - now
;; (negative when a timer is overdue, exactly as production returns).
(defun kt-next-timing (timers now)
  (if (atom timers)
      nil
      (- (kt-min-next timers) now)))

;; update-idle-timers' updating-timers (fire order = list order).
(defun kt-fired (timers now)
  (cond ((atom timers) nil)
        ((kt-due-p (car timers) now)
         (cons (car timers) (kt-fired (cdr timers) now)))
        (t (kt-fired (cdr timers) now))))

;; What survives in *idle-timer-list* (both set-differences).  Order caveat
;; in the header: production's set-difference order is unspecified; the model
;; keeps input order and the differential compares as sets.
(defun kt-remaining (timers now)
  (cond ((atom timers) nil)
        ((kt-due-p (car timers) now)
         (kt-remaining (cdr timers) now))
        (t (cons (car timers) (kt-remaining (cdr timers) now)))))

;; Fired repeat timers, parked in *processed-idle-timer-list* with last-time
;; UNCHANGED (refreshed only by the next idle period's start-idle-timers).
(defun kt-processed (timers now)
  (cond ((atom timers) nil)
        ((and (kt-due-p (car timers) now)
              (ktimer-repeat (car timers)))
         (cons (car timers) (kt-processed (cdr timers) now)))
        (t (kt-processed (cdr timers) now))))

;; Fired one-shot timers: expired and deleted (production's dead-store of
;; last-time on these removed timers is transcribed as plain removal).
(defun kt-expired (timers now)
  (cond ((atom timers) nil)
        ((and (kt-due-p (car timers) now)
              (not (ktimer-repeat (car timers))))
         (cons (car timers) (kt-expired (cdr timers) now)))
        (t (kt-expired (cdr timers) now))))

(local
 (defthm kt-min-next-<=-car
   (implies (consp timers)
            (<= (kt-min-next timers)
                (kt-next-time (car timers))))))

(local
 (defthm kt-min-next-<=-cdr
   (implies (consp (cdr timers))
            (<= (kt-min-next timers)
                (kt-min-next (cdr timers))))))

;; The computed deadline never extends past ANY timer's due time.
(defthm kt-min-next-lower-bound
  (implies (member-equal tm timers)
           (<= (kt-min-next timers) (kt-next-time tm))))

(local
 (defthm kt-nothing-due-at-or-before-min
   (implies (<= t2 (kt-min-next timers))
            (equal (kt-fired timers t2) nil))))

;; Never sleeps past a due timer: at every wake time up to and including
;; now + next-timing, NOTHING fires -- so sleeping exactly next-timing ms
;; cannot skip a firing.
(defthm kt-never-sleeps-past-due
  (implies (and (consp timers)
                (rationalp now)
                (<= t2 (+ now (kt-next-timing timers now))))
           (equal (kt-fired timers t2) nil))
  :hints (("Goal" :use (:instance kt-nothing-due-at-or-before-min)
           :in-theory (disable kt-nothing-due-at-or-before-min kt-fired))))

;; No wakeup fires when nothing is due, and every wakeup strictly past the
;; earliest due-time fires: fired is non-empty IFF the clock is strictly past
;; the minimum next-time (iff next-timing at the wake time is negative).
(defthm kt-wakeup-fires-iff-something-overdue
  (iff (consp (kt-fired timers t2))
       (and (consp timers)
            (< (kt-min-next timers) t2))))

;; The 1 ms granularity boundary, exactly: waking AT the deadline fires
;; nothing (strict <)...
(defthm kt-deadline-wakeup-fires-nothing
  (equal (kt-fired timers (kt-min-next timers)) nil)
  :hints (("Goal" :use (:instance kt-nothing-due-at-or-before-min
                                  (t2 (kt-min-next timers)))
           :in-theory (disable kt-nothing-due-at-or-before-min kt-fired))))

;; ... and the very next ms tick fires the earliest timer.
(defthm kt-first-tick-after-deadline-fires
  (implies (consp timers)
           (consp (kt-fired timers (+ 1 (kt-min-next timers)))))
  :hints (("Goal"
           :use (:instance kt-wakeup-fires-iff-something-overdue
                           (t2 (+ 1 (kt-min-next timers))))
           :in-theory (disable kt-wakeup-fires-iff-something-overdue
                               kt-fired))))

;; Nothing is lost by update-idle-timers' set-difference bookkeeping: every
;; timer lands in exactly one of fired/remaining, and every fired timer in
;; exactly one of expired/processed.
(defthm kt-fired-remaining-partition
  (equal (+ (len (kt-fired timers now))
            (len (kt-remaining timers now)))
         (len timers)))

(defthm kt-fired-splits-into-expired-and-processed
  (equal (+ (len (kt-expired timers now))
            (len (kt-processed timers now)))
         (len (kt-fired timers now))))

;; Ground witness against production's own fixed corpus
;; (tests/common/timer.lisp compute-the-time-for-the-next-idle-timer...):
;; two idle timers of 10 ms and 20 ms started at virtual time 0.
(defthm kt-ground-witness
  (let ((timers (list (mk-ktimer 1 10 nil 0)
                      (mk-ktimer 2 20 t 0))))
    (and (equal (kt-next-timing nil 5) nil)
         (equal (kt-next-timing timers 0) 10)
         (equal (kt-next-timing timers 2) 8)
         (equal (kt-next-timing timers 12) -2)
         ;; strict <: at the deadline nothing fires, one tick later it does
         (equal (kt-fired timers 10) nil)
         (equal (kt-fired timers 11) (list (mk-ktimer 1 10 nil 0)))
         (equal (kt-remaining timers 11) (list (mk-ktimer 2 20 t 0)))
         ;; both overdue: one-shot expires, repeat is parked
         (equal (kt-expired timers 30) (list (mk-ktimer 1 10 nil 0)))
         (equal (kt-processed timers 30) (list (mk-ktimer 2 20 t 0)))))
  :rule-classes nil)
