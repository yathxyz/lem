;;;; verified/interrupt-model.lisp -- Interrupt-delivery protocol model (SPEC-VK VK-8).
;;;;
;;;; One source of truth (SPEC-VK Constraint 2): this same file is certified by
;;;; ACL2 (scripts/run-proofs.sh) AND loaded verbatim into the Lem SBCL image
;;;; through verified/shim.lisp.
;;;;
;;;; PRODUCTION SOURCE TRANSCRIBED (production is the spec):
;;;; src/buffer/interrupt.lisp, whole file.  Two special variables --
;;;; *interrupts-enabled* (initially T) and *interrupted* (initially NIL) --
;;;; and three operations:
;;;;
;;;;   * (without-interrupts BODY):
;;;;       (let ((prev-enabled *interrupts-enabled*)   ; save
;;;;             (*interrupts-enabled* nil))           ; disable
;;;;         (prog1 (progn BODY)
;;;;           (when (and *interrupted* prev-enabled)  ; exit deliver-check
;;;;             (%without-interrupts                  ; sb-sys atomicity
;;;;               (setf *interrupted* nil)
;;;;               (error 'editor-interrupt)))))
;;;;   * (check-interrupt): when *interrupted*: clear it and signal
;;;;       editor-interrupt -- an explicit poll point, honored REGARDLESS of
;;;;       *interrupts-enabled* (that is the point: polls are the sanctioned
;;;;       delivery windows inside a without-interrupts region).
;;;;   * (interrupt &optional force): runs in the target thread via
;;;;       bt2:interrupt-thread.  force => signal editor-interrupt
;;;;       UNCONDITIONALLY (before and regardless of any enabled check);
;;;;       else if *interrupts-enabled* => signal immediately;
;;;;       else => (setf *interrupted* t)  (defer; NOTE: a second deferred
;;;;       arrival coalesces -- *interrupted* is a flag, not a counter).
;;;;
;;;; ACTION ALPHABET (trace = list of actions; step total over (state,action)):
;;;;   (:enter)       -- without-interrupts entry: push the current enabled
;;;;                     value (prev-enabled) on the nesting stack, disable.
;;;;   (:exit)        -- NORMAL return of a without-interrupts body: run the
;;;;                     exit deliver-check (deliver iff pending and the saved
;;;;                     prev-enabled is T, i.e. iff this exit re-enables),
;;;;                     then pop/restore.  In production the error inside the
;;;;                     prog1 unwinds the LET, restoring *interrupts-enabled*
;;;;                     to prev-enabled -- the model's post-state (enabled =
;;;;                     prev) is the post-unwind state.
;;;;   (:exit-abort)  -- a NON-LOCAL exit (error/throw, including an
;;;;                     editor-interrupt delivered deeper inside) unwinding
;;;;                     through the without-interrupts LET: the dynamic
;;;;                     binding is restored but the prog1 deliver-check never
;;;;                     runs.  Production reality, needed for one-source
;;;;                     fidelity: every in-region delivery itself unwinds the
;;;;                     enclosing regions through exactly this path.
;;;;   (:poll)        -- check-interrupt.
;;;;   (:arrive F)    -- interrupt with force flag F, at any interleaving
;;;;                     point (bt2:interrupt-thread runs it in-thread).
;;;;   Delivery (the editor-interrupt signal) is an OBSERVABLE EFFECT of
;;;;   :exit/:poll/:arrive steps (deliver-p below), counted in the delivered
;;;;   field -- production delivery is synchronous inside those operations,
;;;;   never a separately scheduled event.
;;;;
;;;; STATE: (enabled stack pending delivered torn)
;;;;   enabled   -- *interrupts-enabled*
;;;;   stack     -- saved prev-enabled values, innermost first (the dynamic
;;;;                LET nesting of open without-interrupts regions);
;;;;                (consp stack) = "inside a critical region"
;;;;   pending   -- *interrupted*
;;;;   delivered -- count of editor-interrupt signals (observable)
;;;;   torn      -- GHOST FLAG for obligation 2: set iff a delivery ever
;;;;                happens STRICTLY INSIDE a critical region through a
;;;;                non-poll, non-force path.  Sanctioned deliveries never
;;;;                set it: :poll is the explicit poll window; a forced
;;;;                :arrive bypasses deferral BY SPECIFICATION (production's
;;;;                force branch signals before any enabled check -- the
;;;;                hard-abort escape used by send-abort-event); an :exit
;;;;                delivery sets it only if the exit leaves the machine
;;;;                still nested (impossible in reachable states -- that is
;;;;                the theorem).
;;;;
;;;; THEOREMS (quantified over ALL traces by structural induction):
;;;;   1. Safety (obligation 2, "no torn state"): wf-int is an inductive
;;;;      invariant; reachable states never have torn set
;;;;      (reachable-never-torn), and from any reachable in-critical state the
;;;;      only delivering steps are :poll, forced :arrive, or the outermost
;;;;      :exit -- which ends the region (safety-delivery-inside-critical).
;;;;   2. Nesting (obligation 3): exit restores the enabled state saved at
;;;;      the matching enter, at arbitrary nesting depth, for normal AND
;;;;      abort exits (nesting-lemma / exit-restores-matching-enter).
;;;;   3. Force (obligation 4): a forced arrive delivers immediately in EVERY
;;;;      state -- enabled, disabled, nested -- exactly production's
;;;;      unconditional (error ...) branch (force-arrive-delivers-immediately);
;;;;      a non-forced arrive delivers immediately iff enabled, else defers
;;;;      (arrive-while-enabled-delivers, arrive-while-disabled-defers).
;;;;   4. Liveness (obligation 1, "no lost interrupt"): every trace containing
;;;;      an arrival followed by a poll, or by an abort-free suffix that ends
;;;;      re-enabled (the "full exit to enabled" of the spec), contains a
;;;;      delivery (liveness-no-lost-interrupt).  The abort-free proviso is
;;;;      honest: production's deliver-check sits on the normal-return path
;;;;      only, so an error unwinding out of the outermost region skips it and
;;;;      the pending flag survives until the next poll / normal outermost
;;;;      exit / enabled arrival.
;;;;
;;;; COALESCING (documented, deliberate): delivered counts DELIVERIES.  Two
;;;; deferred arrivals inside one region coalesce into one delivery (the flag
;;;; semantics above) -- so "exactly once per arrival" holds per pending
;;;; window, which is what the stress suite asserts (one in-flight arrival
;;;; per run; tests/pbt/interrupt-stress.lisp).
;;;;
;;;; TRUST-BASE RESIDUE (SPEC-VK standing risks): fidelity of this
;;;; interleaving model to SBCL's interrupt machinery.  In particular
;;;; %without-interrupts (sb-sys) makes production's clear-pending+signal
;;;; atomic against further interruptions -- modeled here as the delivery
;;;; being one atomic step -- and bt2:interrupt-thread's own delivery points
;;;; (foreign calls, pseudo-atomic sections) are below this model.  The
;;;; threaded stress suite runs the REAL macros under real
;;;; bt2:interrupt-thread to pin exactly this residue.
;;;;
;;;; EXEC PATH (functions the in-image suite tests/pbt/interrupt-stress.lisp
;;;; calls): int-init, int-run, wf-int, ist-enabled, ist-stack, ist-pending,
;;;; ist-torn, deliver-count, net-balanced (ist-delivered is model-internal:
;;;; tests observe the count via deliver-count, so it is not exported).
;;;; All use only CL homonyms plus the already
;;;; whitelisted natp -- NO shim whitelist growth for VK-8.  ACL2 strings and
;;;; characters are never used.

(in-package "ACL2")

;; Lemma library for arithmetic (proof-only: local, nothing exec-reachable).
(local (include-book "arithmetic/top-with-meta" :dir :system))

;;; ===========================================================================
;;; State record and actions
;;; ===========================================================================

(defun mk-ist (enabled stack pending delivered torn)
  (list enabled stack pending delivered torn))

(defun ist-enabled (st) (nth 0 st))
(defun ist-stack (st) (nth 1 st))
(defun ist-pending (st) (nth 2 st))
(defun ist-delivered (st) (nth 3 st))
(defun ist-torn (st) (nth 4 st))

;; Initial state: *interrupts-enabled* = T, *interrupted* = NIL, no open
;; regions, nothing delivered.
(defun int-init ()
  (mk-ist t nil nil 0 nil))

;; An action is a keyword or (keyword arg...); :arrive carries the force flag.
(defun act-name (act) (if (consp act) (car act) act))
(defun act-force (act) (if (consp act) (cadr act) nil))

(defun in-critical-p (st) (consp (ist-stack st)))

;;; ===========================================================================
;;; deliver-p: does this step signal editor-interrupt?  (Transcribes the three
;;; production signal sites; the step function below counts exactly these.)
;;; ===========================================================================

(defun deliver-p (st act)
  (let ((name (act-name act)))
    (cond
      ;; without-interrupts exit check: (when (and *interrupted* prev-enabled))
      ((eq name :exit)
       (and (consp (ist-stack st))
            (ist-pending st)
            (if (car (ist-stack st)) t nil)))
      ;; check-interrupt: (when *interrupted*)
      ((eq name :poll)
       (if (ist-pending st) t nil))
      ;; interrupt: force => always; else iff *interrupts-enabled*
      ((eq name :arrive)
       (if (act-force act) t (if (ist-enabled st) t nil)))
      (t nil))))

;;; ===========================================================================
;;; The step function (TOTAL over (state, action))
;;; ===========================================================================

(defun int-step (st act)
  (let ((name (act-name act)))
    (cond
      ;; without-interrupts entry: save prev-enabled, disable.
      ((eq name :enter)
       (mk-ist nil
               (cons (ist-enabled st) (ist-stack st))
               (ist-pending st) (ist-delivered st) (ist-torn st)))
      ;; Normal exit: deliver-check, then pop/restore (see header).
      ((eq name :exit)
       (if (atom (ist-stack st))
           st                            ; unmatched exit: no-op (totality)
           (let ((prev (car (ist-stack st))))
             (if (and (ist-pending st) prev)
                 ;; (setf *interrupted* nil) + (error 'editor-interrupt);
                 ;; the unwind restores enabled to prev.  Torn iff still
                 ;; nested afterwards (never, in reachable states).
                 (mk-ist prev (cdr (ist-stack st)) nil
                         (+ 1 (ist-delivered st))
                         (if (ist-torn st) t (consp (cdr (ist-stack st)))))
                 (mk-ist prev (cdr (ist-stack st)) (ist-pending st)
                         (ist-delivered st) (ist-torn st))))))
      ;; Non-local exit: dynamic-binding restore WITHOUT the deliver-check.
      ((eq name :exit-abort)
       (if (atom (ist-stack st))
           st
           (mk-ist (car (ist-stack st)) (cdr (ist-stack st))
                   (ist-pending st) (ist-delivered st) (ist-torn st))))
      ;; check-interrupt: sanctioned poll window -- never torn.
      ((eq name :poll)
       (if (ist-pending st)
           (mk-ist (ist-enabled st) (ist-stack st) nil
                   (+ 1 (ist-delivered st)) (ist-torn st))
           st))
      ((eq name :arrive)
       (cond
         ;; force: unconditional signal, *interrupted* untouched; sanctioned
         ;; bypass -- never torn.
         ((act-force act)
          (mk-ist (ist-enabled st) (ist-stack st) (ist-pending st)
                  (+ 1 (ist-delivered st)) (ist-torn st)))
         ;; enabled: immediate signal, *interrupted* untouched.  Torn iff it
         ;; happened inside a region (never, in reachable states: enabled
         ;; implies no open region).
         ((ist-enabled st)
          (mk-ist (ist-enabled st) (ist-stack st) (ist-pending st)
                  (+ 1 (ist-delivered st))
                  (if (ist-torn st) t (in-critical-p st))))
         ;; disabled: defer -- (setf *interrupted* t).
         (t
          (mk-ist (ist-enabled st) (ist-stack st) t
                  (ist-delivered st) (ist-torn st)))))
      (t st))))

;; Run an arbitrary action trace.  Reachable state := (int-run (int-init)
;; acts) for SOME acts -- quantifying over ACTS quantifies over every
;; interleaving of regions, polls and arrivals.
(defun int-run (st acts)
  (if (atom acts)
      st
      (int-run (int-step st (car acts)) (cdr acts))))

;; Deliveries along a trace (the observable event count).
(defun deliver-count (st acts)
  (if (atom acts)
      0
      (+ (if (deliver-p st (car acts)) 1 0)
         (deliver-count (int-step st (car acts)) (cdr acts)))))

(defthm natp-deliver-count
  (natp (deliver-count st acts))
  :rule-classes (:rewrite :type-prescription))

;; The step function counts exactly the deliver-p deliveries.
(defthm delivered-of-int-step
  (equal (ist-delivered (int-step st act))
         (if (deliver-p st act)
             (+ 1 (ist-delivered st))
             (ist-delivered st))))

;;; ===========================================================================
;;; The inductive invariant
;;; ===========================================================================

;; Stack well-formedness: production binds *interrupts-enabled* to NIL for
;; the whole region body, so every nested enter saves NIL; only the bottom
;; (outermost) frame saves T -- and it saves exactly T because the machine
;; starts enabled.
(defun ok-stack (s)
  (if (atom s)
      (null s)
      (if (atom (cdr s))
          (and (equal (car s) t) (null (cdr s)))
          (and (null (car s)) (ok-stack (cdr s))))))

(defun wf-int (st)
  (and ;; the two flags are honest booleans
       (or (equal (ist-enabled st) t) (equal (ist-enabled st) nil))
       (or (equal (ist-pending st) t) (equal (ist-pending st) nil))
       (natp (ist-delivered st))
       (ok-stack (ist-stack st))
       ;; enabled exactly when no region is open
       (equal (ist-enabled st) (atom (ist-stack st)))
       ;; obligation 2, as a state property: no torn delivery ever happened
       (not (ist-torn st))))

(defthm wf-int-of-int-init
  (wf-int (int-init)))

(defthm wf-int-of-int-step
  (implies (wf-int st)
           (wf-int (int-step st act))))

(defthm wf-int-of-int-run
  (implies (wf-int st)
           (wf-int (int-run st acts)))
  :hints (("Goal" :in-theory (disable wf-int int-step))))

(defthm wf-int-of-reachable
  (wf-int (int-run (int-init) acts))
  :hints (("Goal" :in-theory (disable wf-int int-step int-init int-run))))

;;; ===========================================================================
;;; VK-8 obligation 2 (safety): delivered-inside-critical is impossible
;;; ===========================================================================

(defthm wf-int-implies-not-torn
  (implies (wf-int st)
           (not (ist-torn st))))

;; In every reachable state -- i.e. over ALL traces -- no delivery has ever
;; happened strictly inside a without-interrupts region other than through an
;; explicit poll or a forced arrive.
(defthm reachable-never-torn
  (not (ist-torn (int-run (int-init) acts)))
  :hints (("Goal"
           :use ((:instance wf-int-of-reachable)
                 (:instance wf-int-implies-not-torn
                            (st (int-run (int-init) acts))))
           :in-theory (disable wf-int int-run wf-int-of-reachable
                               wf-int-implies-not-torn))))

;; Step-level characterization: from any well-formed in-critical state, the
;; ONLY delivering steps are the explicit poll, the forced arrive, or the
;; outermost exit -- and that exit LEAVES the critical region.
(defthm safety-delivery-inside-critical
  (implies (and (wf-int st)
                (in-critical-p st)
                (deliver-p st act))
           (or (equal (act-name act) :poll)
               (and (equal (act-name act) :arrive) (act-force act))
               (and (equal (act-name act) :exit)
                    (not (in-critical-p (int-step st act))))))
  :rule-classes nil)

;;; ===========================================================================
;;; VK-8 obligation 3 (nesting): exit restores the enabled state saved at the
;;; matching enter, at arbitrary depth, for normal AND abort exits
;;; ===========================================================================

;; ACTS closes exactly D trace-open regions: every :exit/:exit-abort matches
;; an open region (its own :enter or one of the D), and the net depth ends 0.
(defun net-balanced (acts d)
  (if (atom acts)
      (equal d 0)
      (let ((name (act-name (car acts))))
        (cond ((eq name :enter)
               (net-balanced (cdr acts) (+ d 1)))
              ((or (eq name :exit) (eq name :exit-abort))
               (and (< 0 d) (net-balanced (cdr acts) (- d 1))))
              (t (net-balanced (cdr acts) d))))))

(local
 (defun nest-ind (st acts d)
   (if (atom acts)
       (list st d)
       (let ((name (act-name (car acts))))
         (nest-ind (int-step st (car acts))
                   (cdr acts)
                   (cond ((eq name :enter) (+ d 1))
                         ((or (eq name :exit) (eq name :exit-abort)) (- d 1))
                         (t d)))))))

;; The stack IS a stack: a trace that closes its D open regions pops exactly
;; their D frames, restoring enabled to the value saved at the outermost of
;; them, and leaves the deeper stack untouched.  No wf hypothesis: this holds
;; from EVERY state.
(defthm nesting-lemma
  (implies (and (net-balanced acts d)
                (natp d)
                (<= d (len (ist-stack st))))
           (and (equal (ist-stack (int-run st acts))
                       (nthcdr d (ist-stack st)))
                (equal (ist-enabled (int-run st acts))
                       (if (equal d 0)
                           (ist-enabled st)
                           (nth (- d 1) (ist-stack st))))))
  :rule-classes nil
  :hints (("Goal" :induct (nest-ind st acts d))))

;; A self-contained balanced trace restores enabled and the whole region
;; nesting exactly.
(defthm nesting-balanced-restores
  (implies (net-balanced acts 0)
           (and (equal (ist-stack (int-run st acts)) (ist-stack st))
                (equal (ist-enabled (int-run st acts)) (ist-enabled st))))
  :hints (("Goal" :use ((:instance nesting-lemma (d 0)))
           :in-theory (disable int-run net-balanced))))

;; THE matching-enter statement: enter a region, run ANY body that closes it
;; (its final :exit or :exit-abort is the matching exit; body may nest
;; arbitrarily deep) -- enabled and the outer nesting come back exactly.
(defthm exit-restores-matching-enter
  (implies (net-balanced body 1)
           (and (equal (ist-enabled (int-run (int-step st '(:enter)) body))
                       (ist-enabled st))
                (equal (ist-stack (int-run (int-step st '(:enter)) body))
                       (ist-stack st))))
  :hints (("Goal" :use ((:instance nesting-lemma
                                   (st (int-step st '(:enter)))
                                   (acts body)
                                   (d 1)))
           :in-theory (disable int-run net-balanced))))

;;; ===========================================================================
;;; VK-8 obligation 4 (force): force bypasses deferral exactly as specified
;;; ===========================================================================

;; Production's force branch signals BEFORE any enabled check: a forced
;; arrive delivers immediately in EVERY state -- enabled, disabled, nested.
(defthm force-arrive-delivers-immediately
  (implies (and (equal (act-name act) :arrive)
                (act-force act))
           (and (deliver-p st act)
                (equal (ist-delivered (int-step st act))
                       (+ 1 (ist-delivered st))))))

;; A non-forced arrive delivers immediately exactly when enabled ...
(defthm arrive-while-enabled-delivers
  (implies (and (equal (act-name act) :arrive)
                (ist-enabled st))
           (and (deliver-p st act)
                (equal (ist-delivered (int-step st act))
                       (+ 1 (ist-delivered st))))))

;; ... and otherwise defers: no delivery, pending set.
(defthm arrive-while-disabled-defers
  (implies (and (equal (act-name act) :arrive)
                (not (act-force act))
                (not (ist-enabled st)))
           (and (not (deliver-p st act))
                (equal (ist-delivered (int-step st act)) (ist-delivered st))
                (equal (ist-pending (int-step st act)) t))))

;;; ===========================================================================
;;; VK-8 obligation 1 (liveness): no lost interrupt
;;; ===========================================================================

(defun has-poll (acts)
  (if (atom acts)
      nil
      (or (eq (act-name (car acts)) :poll)
          (has-poll (cdr acts)))))

(defun abort-free (acts)
  (if (atom acts)
      t
      (and (not (eq (act-name (car acts)) :exit-abort))
           (abort-free (cdr acts)))))

;; Pending is cleared ONLY by a delivery.
(defthm pending-persists-without-delivery-step
  (implies (and (ist-pending st)
                (not (deliver-p st act)))
           (ist-pending (int-step st act))))

;; A pending interrupt survives to the next poll: any trace with a poll
;; delivers.
(defthm liveness-poll
  (implies (and (ist-pending st)
                (has-poll acts))
           (< 0 (deliver-count st acts)))
  :hints (("Goal" :induct (deliver-count st acts))))

;; Without aborts and without a delivery, "pending while disabled" persists:
;; only a delivering exit can re-enable past a pending flag.
(defthm pending-disabled-persist-step
  (implies (and (ist-pending st)
                (not (ist-enabled st))
                (not (deliver-p st act))
                (not (eq (act-name act) :exit-abort)))
           (and (ist-pending (int-step st act))
                (not (ist-enabled (int-step st act))))))

(defthm pending-disabled-persist-run
  (implies (and (ist-pending st)
                (not (ist-enabled st))
                (abort-free acts)
                (equal (deliver-count st acts) 0))
           (and (ist-pending (int-run st acts))
                (not (ist-enabled (int-run st acts)))))
  :hints (("Goal" :induct (deliver-count st acts))))

;; A pending interrupt survives to the outermost normal exit: an abort-free
;; trace that ends re-enabled delivers.
(defthm liveness-exit-to-enabled
  (implies (and (ist-pending st)
                (not (ist-enabled st))
                (abort-free acts)
                (ist-enabled (int-run st acts)))
           (< 0 (deliver-count st acts)))
  :hints (("Goal" :use ((:instance pending-disabled-persist-run))
           :in-theory (disable pending-disabled-persist-run
                               int-run deliver-count))))

;; Composed: from ANY state, an arrival followed by a poll, or by an
;; abort-free continuation that ends re-enabled, is delivered.
(defthm liveness-arrive-then-poll-or-exit
  (implies (or (has-poll post)
               (and (abort-free post)
                    (ist-enabled (int-run (int-step st (list :arrive f))
                                          post))))
           (< 0 (deliver-count st (cons (list :arrive f) post))))
  :rule-classes nil
  :hints (("Goal"
           :use ((:instance liveness-poll
                            (st (int-step st (list :arrive f)))
                            (acts post))
                 (:instance liveness-exit-to-enabled
                            (st (int-step st (list :arrive f)))
                            (acts post)))
           :in-theory (disable liveness-poll liveness-exit-to-enabled))))

;; A forced arrival is delivered in every trace, unconditionally.
(defthm liveness-force-arrive
  (< 0 (deliver-count st (cons (list :arrive t) post))))

;; Trace-composition lemmas for the top-level statement.
(defthm int-run-of-append
  (equal (int-run st (append a b))
         (int-run (int-run st a) b)))

(defthm deliver-count-of-append
  (equal (deliver-count st (append a b))
         (+ (deliver-count st a)
            (deliver-count (int-run st a) b))))

(defthm int-run-of-cons
  (equal (int-run st (cons a b))
         (int-run (int-step st a) b)))

(defthm deliver-count-of-cons
  (equal (deliver-count st (cons a b))
         (+ (if (deliver-p st a) 1 0)
            (deliver-count (int-step st a) b))))

;; THE liveness theorem (obligation 1), over complete traces from the initial
;; state: a trace containing an arrival, followed within the trace by a poll
;; or by an abort-free run to a re-enabled state, contains a delivery.
(defthm liveness-no-lost-interrupt
  (implies (or (has-poll post)
               (and (abort-free post)
                    (ist-enabled
                     (int-run (int-init)
                              (append pre (cons (list :arrive f) post))))))
           (< 0 (deliver-count (int-init)
                               (append pre (cons (list :arrive f) post)))))
  :rule-classes nil
  :hints (("Goal"
           :use ((:instance liveness-arrive-then-poll-or-exit
                            (st (int-run (int-init) pre))))
           :in-theory (disable int-run deliver-count int-init int-step
                               deliver-p))))

;; Ground witness (non-vacuity guard for liveness-no-lost-interrupt): both
;; disjuncts of the liveness hypothesis are satisfiable on concrete traces,
;; and delivery actually occurs on each.  Certifies by evaluation, so a
;; future edit that makes the hypothesis unsatisfiable fails certification
;; here instead of leaving the implication above vacuously true.
;;   Disjunct 1: an arrival followed by a poll -- pre = nil, post = ((:poll)).
;;   Disjunct 2: an arrival deferred inside a region, delivered by the
;;   outermost normal exit -- pre = ((:enter)), post = ((:exit)), which is
;;   abort-free and ends re-enabled with the pending flag clear.
(defthm liveness-witness-ground
  (and ;; disjunct 1 instance: (pre nil) (f nil) (post '((:poll)))
       (has-poll '((:poll)))
       (equal (deliver-count (int-init) '((:arrive nil) (:poll))) 1)
       ;; disjunct 2 instance: (pre '((:enter))) (f nil) (post '((:exit)))
       (abort-free '((:exit)))
       (ist-enabled (int-run (int-init) '((:enter) (:arrive nil) (:exit))))
       (equal (deliver-count (int-init) '((:enter) (:arrive nil) (:exit))) 1)
       (not (ist-pending (int-run (int-init)
                                  '((:enter) (:arrive nil) (:exit))))))
  :rule-classes nil)
