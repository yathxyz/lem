;;;; verified/crash-safety.lisp -- Crash-safety protocol model (SPEC-VK VK-6).
;;;;
;;;; One source of truth (SPEC-VK Constraint 2): this same file is certified by
;;;; ACL2 (scripts/run-proofs.sh) AND loaded verbatim into the Lem SBCL image
;;;; through verified/shim.lisp.
;;;;
;;;; WHAT THIS MODELS.  The DS-2 atomic save + DS-3 checkpoint interplay as a
;;;; small-step operational model over an abstract filesystem, with a CRASH
;;;; transition enabled after every step.  "Model checking" is an ACL2 theorem:
;;;; an invariant proved inductive over the step relation, hence holding in
;;;; every reachable state -- including every crash state (SPEC-VK VK-6).
;;;;
;;;; PRODUCTION SOURCES TRANSCRIBED (production is the spec):
;;;;   * Atomic save: src/buffer/file-utils.lisp `write-file-atomically'
;;;;     (lines 243-291).  Step sequence: create temp (open-atomic-temp-stream,
;;;;     :if-exists :error), write temp (funcall writer), fsync temp
;;;;     (fsync-stream: finish-output + sb-posix:fsync, then close), preserve
;;;;     metadata (chown/chmod -- no content effect), rename temp over target
;;;;     (sb-posix:rename), plus the unwind-protect cleanup that deletes the
;;;;     temp when the rename never committed (the :save-abort action).
;;;;   * Checkpoint write: src/ext/checkpoint.lisp
;;;;     `write-string-to-file-atomically' (lines 88-112).  Step sequence:
;;;;     create temp (:if-exists :supersede), write temp (write-string),
;;;;     fsync temp (fsync-stream: finish-output + sb-posix:fsync, then
;;;;     close -- added by VK-4 hardening; before it the checkpoint temp was
;;;;     never synced), rename temp over the checkpoint file, plus its
;;;;     unwind-protect temp cleanup (:cp-abort).
;;;;   * Checkpoint delete on save: src/ext/checkpoint.lisp
;;;;     `delete-checkpoint-on-save' (lines 217-219), registered on the global
;;;;     after-save-hook (line 256).  HOOK ORDERING, VERIFIED IN PRODUCTION:
;;;;     src/buffer/file.lisp `call-with-write-hook' (lines 182-186) runs
;;;;     after-save hooks strictly AFTER the writer function returns, and
;;;;     `write-file-atomically' returns normally only after sb-posix:rename
;;;;     has committed -- a failed rename signals editor-error, which unwinds
;;;;     past run-after-save-hooks so the delete hook never runs.  Hence the
;;;;     :save-delete-checkpoint step is enabled only at save-pc 5 (renamed).
;;;;
;;;; FILESYSTEM AXIOMS (trust base -- these DEFINE the crash transition; see
;;;; verified/README.md "Trust base"):
;;;;   A1. POSIX rename atomicity: a name always refers to the complete old
;;;;       file or the complete new file, never a mixture (rename is modeled
;;;;       as an atomic swap of whole file records).
;;;;   A2. fsync durability: file data that was fsync'd survives a crash
;;;;       exactly.
;;;;   A3. Unsynced data: file data that was NOT fsync'd may, at a crash, be
;;;;       lost or torn to an ARBITRARY PREFIX of what was written (the crash
;;;;       action's adversarial choice arguments pick the prefix).
;;;;   A4. Ordered durable metadata: metadata operations (create/rename/
;;;;       unlink) become durable in program order (metadata journaling).  A
;;;;       crash that loses a SUFFIX of metadata operations lands, metadata-
;;;;       wise, in an earlier protocol state -- and every earlier state's
;;;;       crash image is itself covered, because the theorems quantify over
;;;;       ALL action sequences (every prefix of the protocol is reachable).
;;;;       Strict POSIX only promises this after fsync of the directory, which
;;;;       production does not do; ext4/xfs/btrfs metadata journaling provides
;;;;       it.  Documented as trust base.
;;;;
;;;; CHECKPOINT DURABILITY (the former VK-6 residue, CLOSED by VK-4
;;;; hardening).  Axioms A2/A3 are applied UNIFORMLY: rename carries the
;;;; temp's synced flag onto the target name.  BOTH writers now fsync their
;;;; temp before rename -- the save path always did; the checkpoint writer
;;;; gained its fsync in VK-4 hardening (before that, a crash after the
;;;; checkpoint rename could leave the checkpoint torn to a prefix of the
;;;; new content, and the theorems carried a crash-state prefix disjunct).
;;;; A renamed-in checkpoint is therefore durable and the recoverability
;;;; theorem below states EQUALITY in every reachable state, crash states
;;;; included.  The only file that can still tear is the initial CP0
;;;; checkpoint when its durability parameter says it was never synced.
;;;;
;;;; SCENARIO MODELED.  One target file (content OLD, durable), one pending
;;;; save (content NEW), a checkpoint file initially present holding CP0 (the
;;;; previous checkpoint round's content; its durability flag is a parameter),
;;;; and checkpoint writes installing CPC (the current unsaved edits).  The
;;;; initially-present checkpoint is the interesting DS-3 scenario ("buffer
;;;; modified, checkpoint on disk, save runs"); with no checkpoint present the
;;;; delete step deletes nothing and the target theorem is unchanged.
;;;; Production runs checkpoint writes and saves in the single editor thread
;;;; (idle timer / input hook vs. command), so they never interleave; the
;;;; model nevertheless proves the invariant for ARBITRARY interleavings of
;;;; the two protocols' steps (a superset of production's behaviors), so no
;;;; scheduling assumption is load-bearing.
;;;;
;;;; SCOPE BOUNDARY.  Only the default *atomic-save* = T path is modeled.
;;;; The `write-file-in-place' fallback (src/buffer/file-utils.lisp, taken
;;;; when *atomic-save* is NIL or a virtual-file handler claims the target)
;;;; truncates and rewrites the target directly and provides NONE of the
;;;; guarantees proved here.  This matches DS-2 scope (atomic save is the
;;;; default); anyone disabling *atomic-save* opts out of these theorems.
;;;;
;;;; "RECOVERABLE", PRECISELY.  When the target still holds OLD and the buffer
;;;; was modified, the edits are recoverable iff the checkpoint file holds the
;;;; complete CPC: on the next find-file, checkpoint-newer-than-file-p offers
;;;; it and recover-buffer-from-checkpoint restores CPC
;;;; (src/ext/checkpoint.lisp:169-215).  The theorem: in EVERY reachable
;;;; state -- crash states included -- where a checkpoint write has committed
;;;; (cp-done) and the save has not renamed, the target is OLD and the
;;;; checkpoint file is present holding CPC exactly (the fsync-before-rename
;;;; durability above).
;;;;
;;;; REPRESENTATION.  File contents are opaque to the model (in practice VK-1
;;;; codepoint lists; the theorems only compare them and take prefixes, so no
;;;; content typing is assumed).  ACL2 strings/characters are never used.
;;;;
;;;; EXEC PATH (functions the fault-injection driver tests/pbt/
;;;; crash-safety-faults.lisp actually calls): `cs-init', `cs-step', `cs-run',
;;;; `cs-inv', the st-*/file-* accessors, `prefix-p', `take-at-most', and
;;;; `encode-path'.  All use only CL homonyms (cond/if/eq/eql/equal/member/
;;;; and/or/not/car/cdr/cadr/nth/cons/list/append/atom/consp/integerp/</-/<=)
;;;; -- NO shim whitelist growth for VK-6.  The base-36 / name-dispatch
;;;; functions are proof-only models of production's format strings.

(in-package "ACL2")

;; Lemma library for arithmetic (proof-only: local, nothing exec-reachable).
(local (include-book "arithmetic/top-with-meta" :dir :system))

;;; ===========================================================================
;;; Prefixes -- the shape of torn (unsynced, crash-interrupted) file data
;;; ===========================================================================

;; The first N elements of L (a genuine prefix: never padded past L, unlike
;; ACL2's `take').  Total: any non-natural N yields the empty prefix.
(defun take-at-most (n l)
  (if (or (atom l) (not (integerp n)) (<= n 0))
      nil
      (cons (car l) (take-at-most (- n 1) (cdr l)))))

;; A is a prefix of B (element-wise equal).
(defun prefix-p (a b)
  (if (atom a)
      t
      (and (consp b)
           (equal (car a) (car b))
           (prefix-p (cdr a) (cdr b)))))

(defthm prefix-p-of-take-at-most
  (prefix-p (take-at-most n l) l))

(defthm prefix-p-reflexive
  (prefix-p x x))

;;; ===========================================================================
;;; Abstract files and the filesystem state record
;;; ===========================================================================

;; A file on disk: (content synced).  SYNCED = t means the data is on stable
;; storage (axiom A2); nil means it may tear at a crash (axiom A3).  An absent
;; file is represented as NIL where a file record may appear.
(defun mk-file (content synced) (list content synced))
(defun file-content (f) (car f))
(defun file-synced (f) (cadr f))

;; Crash effect on one file (axioms A2/A3): synced data survives exactly;
;; unsynced data becomes an adversarially chosen prefix; absent stays absent.
(defun tear-file (f n)
  (if (atom f)
      f
      (if (file-synced f)
          f
          (mk-file (take-at-most n (file-content f)) (file-synced f)))))

;; State record (positional; immutable scenario parameters ride in the state
;; so every theorem can name them):
;;   0 target     -- the real file (always present; a file record)
;;   1 save-temp  -- the atomic-save temp file, or NIL
;;   2 cp-temp    -- the checkpoint-writer temp file, or NIL
;;   3 checkpoint -- the checkpoint file, or NIL
;;   4 save-pc    -- 0 start, 1 temp-created, 2 temp-written, 3 temp-synced,
;;                   4 metadata-done, 5 renamed, 6 checkpoint-deleted (done),
;;                   7 aborted (unwind-protect cleanup ran)
;;   5 cp-pc      -- 0 idle, 1 temp-created, 2 temp-written, 3 temp-synced
;;   6 crashed    -- boolean; once t, no protocol step fires (terminal)
;;   7 cp-done    -- ghost flag: some checkpoint rename has committed
;;   8 old        -- parameter: initial target content
;;   9 new        -- parameter: content the save writes
;;  10 cpc        -- parameter: content the checkpoint writer installs
;;  11 cp0        -- parameter: initial (previous round's) checkpoint content
(defun mk-st (target save-temp cp-temp checkpoint save-pc cp-pc
              crashed cp-done old new cpc cp0)
  (list target save-temp cp-temp checkpoint save-pc cp-pc
        crashed cp-done old new cpc cp0))

(defun st-target (st) (nth 0 st))
(defun st-save-temp (st) (nth 1 st))
(defun st-cp-temp (st) (nth 2 st))
(defun st-checkpoint (st) (nth 3 st))
(defun st-save-pc (st) (nth 4 st))
(defun st-cp-pc (st) (nth 5 st))
(defun st-crashed (st) (nth 6 st))
(defun st-cp-done (st) (nth 7 st))
(defun st-old (st) (nth 8 st))
(defun st-new (st) (nth 9 st))
(defun st-cpc (st) (nth 10 st))
(defun st-cp0 (st) (nth 11 st))

;; Initial state: target holds OLD durably; a checkpoint from a previous
;; round is present holding CP0 (CP0-SYNCED parameterizes whether that old
;; checkpoint's data has reached stable storage); no temps; nothing ran.
(defun cs-init (old new cpc cp0 cp0-synced)
  (mk-st (mk-file old t) nil nil (mk-file cp0 cp0-synced)
         0 0 nil nil old new cpc cp0))

;;; ===========================================================================
;;; The step relation
;;; ===========================================================================

;; An action is (name choice...); the choices are used only by :crash (the
;; adversarial tear prefixes of axiom A3, one per file slot).
(defun act-arg (act i)
  (if (consp act) (nth i act) nil))

(defun cs-step (st act)
  (let ((name (if (consp act) (car act) act)))
    (if (st-crashed st)
        st                              ; crash is terminal
        (cond
          ;; --- DS-2 atomic save (write-file-atomically) --------------------
          ;; open-atomic-temp-stream: fresh temp, empty, unsynced.
          ((eq name :save-create-temp)
           (if (equal (st-save-pc st) 0)
               (mk-st (st-target st) (mk-file nil nil) (st-cp-temp st)
                      (st-checkpoint st) 1 (st-cp-pc st) (st-crashed st)
                      (st-cp-done st) (st-old st) (st-new st) (st-cpc st)
                      (st-cp0 st))
               st))
          ;; (funcall writer out): temp now holds NEW, still unsynced.
          ((eq name :save-write-temp)
           (if (equal (st-save-pc st) 1)
               (mk-st (st-target st) (mk-file (st-new st) nil) (st-cp-temp st)
                      (st-checkpoint st) 2 (st-cp-pc st) (st-crashed st)
                      (st-cp-done st) (st-old st) (st-new st) (st-cpc st)
                      (st-cp0 st))
               st))
          ;; fsync-stream (+ close): temp data reaches stable storage.
          ((eq name :save-fsync-temp)
           (if (equal (st-save-pc st) 2)
               (mk-st (st-target st)
                      (mk-file (file-content (st-save-temp st)) t)
                      (st-cp-temp st) (st-checkpoint st) 3 (st-cp-pc st)
                      (st-crashed st) (st-cp-done st) (st-old st) (st-new st)
                      (st-cpc st) (st-cp0 st))
               st))
          ;; preserve-file-metadata (chown/chmod): no content effect.
          ((eq name :save-metadata)
           (if (equal (st-save-pc st) 3)
               (mk-st (st-target st) (st-save-temp st) (st-cp-temp st)
                      (st-checkpoint st) 4 (st-cp-pc st) (st-crashed st)
                      (st-cp-done st) (st-old st) (st-new st) (st-cpc st)
                      (st-cp0 st))
               st))
          ;; sb-posix:rename: atomic swap (axiom A1); the target name now
          ;; carries the temp's file record -- content AND synced flag (this
          ;; is where fsync-before-rename earns the durable target).
          ((eq name :save-rename)
           (if (equal (st-save-pc st) 4)
               (mk-st (st-save-temp st) nil (st-cp-temp st)
                      (st-checkpoint st) 5 (st-cp-pc st) (st-crashed st)
                      (st-cp-done st) (st-old st) (st-new st) (st-cpc st)
                      (st-cp0 st))
               st))
          ;; delete-checkpoint-on-save (after-save hook): enabled ONLY after
          ;; the rename committed -- the verified production hook ordering.
          ((eq name :save-delete-checkpoint)
           (if (equal (st-save-pc st) 5)
               (mk-st (st-target st) (st-save-temp st) (st-cp-temp st)
                      nil 6 (st-cp-pc st) (st-crashed st) (st-cp-done st)
                      (st-old st) (st-new st) (st-cpc st) (st-cp0 st))
               st))
          ;; unwind-protect cleanup on error before rename: delete the temp.
          ((eq name :save-abort)
           (if (member (st-save-pc st) '(1 2 3 4))
               (mk-st (st-target st) nil (st-cp-temp st) (st-checkpoint st)
                      7 (st-cp-pc st) (st-crashed st) (st-cp-done st)
                      (st-old st) (st-new st) (st-cpc st) (st-cp0 st))
               st))
          ;; --- DS-3 checkpoint write (write-string-to-file-atomically) -----
          ((eq name :cp-create-temp)
           (if (equal (st-cp-pc st) 0)
               (mk-st (st-target st) (st-save-temp st) (mk-file nil nil)
                      (st-checkpoint st) (st-save-pc st) 1 (st-crashed st)
                      (st-cp-done st) (st-old st) (st-new st) (st-cpc st)
                      (st-cp0 st))
               st))
          ;; (write-string string out): temp now holds CPC, still unsynced.
          ((eq name :cp-write-temp)
           (if (equal (st-cp-pc st) 1)
               (mk-st (st-target st) (st-save-temp st)
                      (mk-file (st-cpc st) nil) (st-checkpoint st)
                      (st-save-pc st) 2 (st-crashed st) (st-cp-done st)
                      (st-old st) (st-new st) (st-cpc st) (st-cp0 st))
               st))
          ;; fsync-stream (+ close): checkpoint temp data reaches stable
          ;; storage (the VK-4 hardening step that closed the VK-6 residue).
          ((eq name :cp-fsync-temp)
           (if (equal (st-cp-pc st) 2)
               (mk-st (st-target st) (st-save-temp st)
                      (mk-file (file-content (st-cp-temp st)) t)
                      (st-checkpoint st) (st-save-pc st) 3 (st-crashed st)
                      (st-cp-done st) (st-old st) (st-new st) (st-cpc st)
                      (st-cp0 st))
               st))
          ;; sb-posix:rename: checkpoint name now carries the SYNCED record
          ;; (this is where fsync-before-rename earns the durable checkpoint).
          ((eq name :cp-rename)
           (if (equal (st-cp-pc st) 3)
               (mk-st (st-target st) (st-save-temp st) nil (st-cp-temp st)
                      (st-save-pc st) 0 (st-crashed st) t
                      (st-old st) (st-new st) (st-cpc st) (st-cp0 st))
               st))
          ;; unwind-protect temp cleanup of the checkpoint writer.
          ((eq name :cp-abort)
           (if (member (st-cp-pc st) '(1 2 3))
               (mk-st (st-target st) (st-save-temp st) nil (st-checkpoint st)
                      (st-save-pc st) 0 (st-crashed st) (st-cp-done st)
                      (st-old st) (st-new st) (st-cpc st) (st-cp0 st))
               st))
          ;; --- CRASH: enabled after every step (axioms A1-A4) --------------
          ((eq name :crash)
           (mk-st (tear-file (st-target st) (act-arg act 1))
                  (tear-file (st-save-temp st) (act-arg act 2))
                  (tear-file (st-cp-temp st) (act-arg act 3))
                  (tear-file (st-checkpoint st) (act-arg act 4))
                  (st-save-pc st) (st-cp-pc st) t (st-cp-done st)
                  (st-old st) (st-new st) (st-cpc st) (st-cp0 st)))
          (t st)))))

;; Run an arbitrary action sequence.  Reachable state := (cs-run (cs-init ...)
;; acts) for SOME acts -- so quantifying over ACTS quantifies over every
;; interleaving and every crash point.
(defun cs-run (st acts)
  (if (atom acts)
      st
      (cs-run (cs-step st (car acts)) (cdr acts))))

;;; ===========================================================================
;;; The inductive invariant
;;; ===========================================================================

;; Each conjunct written as (or (not hyp) concl) so the predicate stays on CL
;; homonyms (IMPLIES is not a CL function; this predicate is exec-reachable).
(defun cs-inv (st)
  (and
   ;; I1: the target file always exists ...
   (consp (st-target st))
   ;; I2: ... and its data is always durable (established by fsync-before-
   ;; rename; this is what makes the target immune to the crash transition).
   (equal (file-synced (st-target st)) t)
   ;; I3: target content tracks the save pc: NEW once renamed, OLD before.
   (if (or (equal (st-save-pc st) 5) (equal (st-save-pc st) 6))
       (equal (file-content (st-target st)) (st-new st))
       (equal (file-content (st-target st)) (st-old st)))
   ;; I4: (not crashed) and save-pc 2 => save temp holds NEW.
   (or (st-crashed st)
       (not (equal (st-save-pc st) 2))
       (and (consp (st-save-temp st))
            (equal (file-content (st-save-temp st)) (st-new st))))
   ;; I5: (not crashed) and save-pc 3/4 => save temp holds NEW, synced --
   ;; exactly what :save-rename installs as the target.
   (or (st-crashed st)
       (not (or (equal (st-save-pc st) 3) (equal (st-save-pc st) 4)))
       (and (consp (st-save-temp st))
            (equal (file-content (st-save-temp st)) (st-new st))
            (equal (file-synced (st-save-temp st)) t)))
   ;; I6: (not crashed) and cp-pc 2 => checkpoint temp holds CPC.
   (or (st-crashed st)
       (not (equal (st-cp-pc st) 2))
       (and (consp (st-cp-temp st))
            (equal (file-content (st-cp-temp st)) (st-cpc st))))
   ;; I6b: (not crashed) and cp-pc 3 => checkpoint temp holds CPC, synced --
   ;; exactly what :cp-rename installs as the checkpoint (mirrors I5).
   (or (st-crashed st)
       (not (equal (st-cp-pc st) 3))
       (and (consp (st-cp-temp st))
            (equal (file-content (st-cp-temp st)) (st-cpc st))
            (equal (file-synced (st-cp-temp st)) t)))
   ;; I7: a present checkpoint is never junk: the old checkpoint, the new
   ;; checkpoint, or (crash states only) a torn prefix of the OLD checkpoint.
   ;; A renamed-in NEW checkpoint is fsync'd and can never tear.
   (or (atom (st-checkpoint st))
       (equal (file-content (st-checkpoint st)) (st-cp0 st))
       (equal (file-content (st-checkpoint st)) (st-cpc st))
       (and (st-crashed st)
            (prefix-p (file-content (st-checkpoint st)) (st-cp0 st))))
   ;; I7s: unsynced checkpoint data is pre-existing: only the initial CP0
   ;; checkpoint (cp0-synced = nil) can be unsynced -- every checkpoint the
   ;; writer installs was fsync'd before its rename.
   (or (atom (st-checkpoint st))
       (equal (file-synced (st-checkpoint st)) t)
       (equal (file-content (st-checkpoint st)) (st-cp0 st))
       (and (st-crashed st)
            (prefix-p (file-content (st-checkpoint st)) (st-cp0 st))))
   ;; I8: checkpoint-deletion ordering: the checkpoint is absent ONLY in the
   ;; post-delete state -- which I3 pins to target = NEW.
   (or (consp (st-checkpoint st))
       (equal (st-save-pc st) 6))
   ;; I9: once a checkpoint write committed (cp-done) a present checkpoint
   ;; holds CPC exactly, durably -- in crash states too (the fsync).
   (or (not (st-cp-done st))
       (atom (st-checkpoint st))
       (and (equal (file-content (st-checkpoint st)) (st-cpc st))
            (equal (file-synced (st-checkpoint st)) t)))))

;;; ===========================================================================
;;; Inductiveness: cs-inv holds in every reachable state (incl. crash states)
;;; ===========================================================================

(defthm cs-inv-of-cs-step
  (implies (cs-inv st)
           (cs-inv (cs-step st act))))

;; The scenario parameters are immutable across steps, runs, and init.
(defthm st-old-of-cs-step
  (equal (st-old (cs-step st act)) (st-old st)))
(defthm st-new-of-cs-step
  (equal (st-new (cs-step st act)) (st-new st)))
(defthm st-cpc-of-cs-step
  (equal (st-cpc (cs-step st act)) (st-cpc st)))
(defthm st-cp0-of-cs-step
  (equal (st-cp0 (cs-step st act)) (st-cp0 st)))

(defthm cs-inv-of-cs-init
  (cs-inv (cs-init old new cpc cp0 cp0-synced)))

(defthm st-old-of-cs-init
  (equal (st-old (cs-init old new cpc cp0 cp0-synced)) old))
(defthm st-new-of-cs-init
  (equal (st-new (cs-init old new cpc cp0 cp0-synced)) new))
(defthm st-cpc-of-cs-init
  (equal (st-cpc (cs-init old new cpc cp0 cp0-synced)) cpc))
(defthm st-cp0-of-cs-init
  (equal (st-cp0 (cs-init old new cpc cp0 cp0-synced)) cp0))

;; From here on the run-level proofs work at the step-lemma abstraction:
;; cs-inv / cs-step stay closed and the rewrite rules above carry the induction.
(defthm cs-inv-of-cs-run
  (implies (cs-inv st)
           (cs-inv (cs-run st acts)))
  :hints (("Goal" :in-theory (disable cs-inv cs-step))))

(defthm st-old-of-cs-run
  (equal (st-old (cs-run st acts)) (st-old st))
  :hints (("Goal" :in-theory (disable cs-step st-old))))
(defthm st-new-of-cs-run
  (equal (st-new (cs-run st acts)) (st-new st))
  :hints (("Goal" :in-theory (disable cs-step st-new))))
(defthm st-cpc-of-cs-run
  (equal (st-cpc (cs-run st acts)) (st-cpc st))
  :hints (("Goal" :in-theory (disable cs-step st-cpc))))
(defthm st-cp0-of-cs-run
  (equal (st-cp0 (cs-run st acts)) (st-cp0 st))
  :hints (("Goal" :in-theory (disable cs-step st-cp0))))

(defthm cs-inv-of-reachable
  (cs-inv (cs-run (cs-init old new cpc cp0 cp0-synced) acts))
  :hints (("Goal" :in-theory (disable cs-inv cs-step cs-init cs-run))))

;; Theory for deriving the top-level corollaries from the invariant: the run
;; term stays closed, cs-inv opens into accessor-level conjuncts, and the
;; parameter rewrites above evaluate the accessors of the reachable state.
(local
 (in-theory (disable cs-run cs-step cs-init cs-inv-of-reachable
                     st-target st-save-temp st-cp-temp st-checkpoint
                     st-save-pc st-cp-pc st-crashed st-cp-done
                     st-old st-new st-cpc st-cp0
                     file-content file-synced prefix-p mk-file tear-file
                     take-at-most)))

;;; ===========================================================================
;;; VK-6 obligation 1: the target is ALWAYS old or new -- never torn, never
;;; lost -- in every reachable state, including every crash state.
;;; ===========================================================================

(defthm crash-safety-target-old-or-new
  (or (equal (file-content
              (st-target (cs-run (cs-init old new cpc cp0 cp0-synced) acts)))
             old)
      (equal (file-content
              (st-target (cs-run (cs-init old new cpc cp0 cp0-synced) acts)))
             new))
  :rule-classes nil
  :hints (("Goal"
           :use ((:instance cs-inv-of-reachable))
           :in-theory (disable cs-run cs-inv-of-reachable))))

;;; ===========================================================================
;;; VK-6 obligation 2: checkpoint-deletion ordering -- if the checkpoint is
;;; absent, the rename has committed (target = NEW).  This is the theorem that
;;; closes the delete-then-crash window: no reachable state has "checkpoint
;;; gone, target still old".
;;; ===========================================================================

(defthm crash-safety-checkpoint-delete-ordering
  (implies (atom (st-checkpoint
                  (cs-run (cs-init old new cpc cp0 cp0-synced) acts)))
           (equal (file-content
                   (st-target (cs-run (cs-init old new cpc cp0 cp0-synced) acts)))
                  new))
  :rule-classes nil
  :hints (("Goal"
           :use ((:instance cs-inv-of-reachable))
           :in-theory (disable cs-run cs-inv-of-reachable))))

;;; ===========================================================================
;;; Checkpoint integrity: a present checkpoint is the old checkpoint, the new
;;; checkpoint, or -- ONLY in a crash state -- a prefix of the OLD checkpoint
;;; content (possible only when the pre-existing CP0 checkpoint was never
;;; synced).  A checkpoint the writer installed is fsync'd before its rename
;;; (VK-4 hardening) and can never tear: no prefix-of-CPC disjunct remains.
;;; ===========================================================================

(defthm crash-safety-checkpoint-never-junk
  (implies (consp (st-checkpoint
                   (cs-run (cs-init old new cpc cp0 cp0-synced) acts)))
           (or (equal (file-content
                       (st-checkpoint
                        (cs-run (cs-init old new cpc cp0 cp0-synced) acts)))
                      cp0)
               (equal (file-content
                       (st-checkpoint
                        (cs-run (cs-init old new cpc cp0 cp0-synced) acts)))
                      cpc)
               (and (st-crashed (cs-run (cs-init old new cpc cp0 cp0-synced) acts))
                    (prefix-p (file-content
                               (st-checkpoint
                                (cs-run (cs-init old new cpc cp0 cp0-synced) acts)))
                              cp0))))
  :rule-classes nil
  :hints (("Goal"
           :use ((:instance cs-inv-of-reachable))
           :in-theory (disable cs-run cs-inv-of-reachable))))

;;; ===========================================================================
;;; Recoverability -- the precise meaning of "old + checkpoint" (obligation 1's
;;; third disjunct).  In EVERY reachable state -- crash states included --
;;; where a checkpoint write has committed and the save has not renamed:
;;;   * the target still holds OLD,
;;;   * the checkpoint file is present, and
;;;   * it holds CPC EXACTLY (the fsync-before-rename added by VK-4 hardening;
;;;     before it, crash states admitted only "a prefix of CPC", and a
;;;     separate no-crash theorem carried the equality).
;;; ===========================================================================

(defthm crash-safety-recoverable-any-state
  (implies (and (st-cp-done (cs-run (cs-init old new cpc cp0 cp0-synced) acts))
                (not (equal (st-save-pc
                             (cs-run (cs-init old new cpc cp0 cp0-synced) acts))
                            5))
                (not (equal (st-save-pc
                             (cs-run (cs-init old new cpc cp0 cp0-synced) acts))
                            6)))
           (and (equal (file-content
                        (st-target
                         (cs-run (cs-init old new cpc cp0 cp0-synced) acts)))
                       old)
                (consp (st-checkpoint
                        (cs-run (cs-init old new cpc cp0 cp0-synced) acts)))
                (equal (file-content
                        (st-checkpoint
                         (cs-run (cs-init old new cpc cp0 cp0-synced) acts)))
                       cpc)))
  :rule-classes nil
  :hints (("Goal"
           :use ((:instance cs-inv-of-reachable))
           :in-theory (disable cs-run cs-inv-of-reachable))))

;;; ===========================================================================
;;; VK-6 obligation 3: encode-path injectivity + namespace disjointness
;;; ===========================================================================

;; VERBATIM port of src/ext/checkpoint.lisp:61-71 `encode-path' to codepoint
;; lists: 47 (#\/) -> (33 115) "!s"; 33 (#\!) -> (33 33) "!!"; anything else
;; passes through.  Every 33 in the output starts a two-codepoint escape, so
;; the escapes form a prefix code.
(defun encode-path (cs)
  (cond ((atom cs) nil)
        ((eql (car cs) 47) (cons 33 (cons 115 (encode-path (cdr cs)))))
        ((eql (car cs) 33) (cons 33 (cons 33 (encode-path (cdr cs)))))
        (t (cons (car cs) (encode-path (cdr cs))))))

(defthm true-listp-of-encode-path
  (true-listp (encode-path cs)))

;; Proof-only inverse witnessing the prefix-code property: 33 always consumes
;; two codepoints ("!s" -> 47, "!x" -> x; only "!!" arises from encode-path),
;; anything else one.
(defun decode-path (cs)
  (cond ((atom cs) nil)
        ((and (eql (car cs) 33) (consp (cdr cs)))
         (if (eql (cadr cs) 115)
             (cons 47 (decode-path (cddr cs)))
             (cons (cadr cs) (decode-path (cddr cs)))))
        (t (cons (car cs) (decode-path (cdr cs))))))

(defthm decode-path-of-encode-path
  (implies (true-listp x)
           (equal (decode-path (encode-path x)) x)))

;; THE injectivity theorem: distinct paths never encode to the same name.
(defthm encode-path-injective
  (implies (and (true-listp a)
                (true-listp b)
                (equal (encode-path a) (encode-path b)))
           (equal a b))
  :rule-classes nil
  :hints (("Goal"
           :use ((:instance decode-path-of-encode-path (x a))
                 (:instance decode-path-of-encode-path (x b)))
           :in-theory (disable decode-path-of-encode-path))))

;;; ---------------------------------------------------------------------------
;;; Full checkpoint names and the production dispatch
;;; (src/ext/checkpoint.lisp `checkpoint-filename', lines 73-84)
;;;
;;;   encoded namespace : (< (length encoded) 200) -> "<encoded>#"
;;;   hash namespace    : otherwise -> "~(~36R~)-<tail>#"  (lowercase base-36
;;;                       of (sxhash true), then "-" (45), tail, "#" (35))
;;;
;;; Production feeds ABSOLUTE paths: buffer-filename comes from
;;; expand-file-name (src/buffer/file-utils.lisp:54-57) and checkpoint-filename
;;; first tries (truename filename) -- both yield paths starting with "/"
;;; (codepoint 47).  The namespace-separation theorems below therefore hypothesize
;;; (car p) = 47; the guarantee production actually has is CONDITIONAL on that
;;; absoluteness (a relative path starting with a base-36 digit would break it
;;; -- production never produces one here).
;;; ---------------------------------------------------------------------------

(defun encoded-name (p)
  (append (encode-path p) (list 35)))

;; Floor/mod lemmas for nat-to-base36's termination (proof-only: local, and
;; placed here so it cannot perturb the state-machine proofs above).
(local (include-book "ihs/quotient-remainder-lemmas" :dir :system))

;; Lowercase base-36 digit codepoints: 0-9 (48-57) and a-z (97-122) -- the
;; alphabet of ~(~36R~).
(defun digit36-cp (d)
  (if (and (integerp d) (<= 0 d) (< d 10))
      (+ 48 d)
      (if (and (integerp d) (<= 10 d) (< d 36))
          (+ 87 d)
          48)))

(defun base36-digit-cp-p (c)
  (and (integerp c)
       (or (and (<= 48 c) (<= c 57))
           (and (<= 97 c) (<= c 122)))))

;; Proof-only model of ~36R over naturals (most significant digit first).
(defun nat-to-base36 (n)
  (declare (xargs :measure (nfix n)))
  (if (or (not (integerp n)) (< n 36))
      (list (digit36-cp n))
      (append (nat-to-base36 (floor n 36))
              (list (digit36-cp (mod n 36))))))

;; Model of the hash-fallback name: base-36 hash digits, "-", tail, "#".
(defun hash-name (h tail)
  (append (nat-to-base36 h) (cons 45 (append tail (list 35)))))

;; The dispatch, with production's length threshold (checkpoint.lisp:81).
(defun checkpoint-name (p h tail)
  (if (< (len (encode-path p)) 200)
      (encoded-name p)
      (hash-name h tail)))

(defthm base36-digit-cp-p-of-digit36-cp
  (base36-digit-cp-p (digit36-cp d)))

(defthm consp-of-nat-to-base36
  (consp (nat-to-base36 n)))

(defthm car-of-append-when-consp
  (implies (consp a)
           (equal (car (append a b)) (car a))))

(defthm car-of-nat-to-base36-is-base36-digit
  (base36-digit-cp-p (car (nat-to-base36 n))))

;; An encoded absolute path starts with "!s" (33 115): the first codepoint of
;; an absolute path is 47.
(defthm encoded-name-of-absolute-starts-with-bang-s
  (implies (eql (car p) 47)
           (and (equal (car (encoded-name p)) 33)
                (equal (cadr (encoded-name p)) 115))))

(defthm hash-name-starts-with-base36-digit
  (base36-digit-cp-p (car (hash-name h tail)))
  :hints (("Goal" :in-theory (disable base36-digit-cp-p))))

(defthm base36-digit-cp-is-not-33
  (implies (base36-digit-cp-p c)
           (not (equal c 33))))

;; NAMESPACE DISJOINTNESS: an encoded absolute-path name can never equal a
;; hash-fallback name -- the first codepoint is 33 vs. a base-36 digit.
(defthm encoded-and-hash-names-disjoint
  (implies (eql (car p) 47)
           (not (equal (encoded-name p) (hash-name h tail))))
  :rule-classes nil
  :hints (("Goal"
           :use ((:instance encoded-name-of-absolute-starts-with-bang-s)
                 (:instance hash-name-starts-with-base36-digit)
                 (:instance base36-digit-cp-is-not-33
                            (c (car (hash-name h tail)))))
           :in-theory (disable encoded-name hash-name
                               encoded-name-of-absolute-starts-with-bang-s
                               hash-name-starts-with-base36-digit
                               base36-digit-cp-p))))

;; Right cancellation of a singleton suffix (for encoded-name injectivity).
(local
 (defun ind2 (a b)
   (if (or (atom a) (atom b))
       (list a b)
       (ind2 (cdr a) (cdr b)))))

(local
 (defthm consp-of-append-singleton
   (consp (append u (list x)))))

(local
 (defthm append-singleton-right-cancel
   (implies (and (true-listp a)
                 (true-listp b)
                 (equal (append a (list x)) (append b (list x))))
            (equal a b))
   :rule-classes nil
   :hints (("Goal" :induct (ind2 a b)))))

;; Injectivity within the encoded namespace, at the full-name level (the
;; trailing "#" cancels).
(defthm encoded-name-injective
  (implies (and (true-listp p)
                (true-listp q)
                (equal (encoded-name p) (encoded-name q)))
           (equal p q))
  :rule-classes nil
  :hints (("Goal"
           :use ((:instance append-singleton-right-cancel
                            (a (encode-path p)) (b (encode-path q)) (x 35))
                 (:instance encode-path-injective (a p) (b q))))))

;; THE DISPATCH GUARANTEE production actually has: for absolute paths, a name
;; collision across the dispatch implies the paths are equal whenever at least
;; one side is in the encoded namespace.  (Two paths BOTH in the hash
;; namespace may still collide when sxhash collides AND the readable tails
;; match -- that intra-hash-namespace residue is documented, not provable,
;; and not fixed here.)
(defthm checkpoint-name-collision-implies-equal-paths
  (implies (and (true-listp p)
                (true-listp q)
                (eql (car p) 47)
                (eql (car q) 47)
                (< (len (encode-path p)) 200)
                (equal (checkpoint-name p hp tp)
                       (checkpoint-name q hq tq)))
           (equal p q))
  :rule-classes nil
  :hints (("Goal"
           :use ((:instance encoded-name-injective)
                 (:instance encoded-and-hash-names-disjoint
                            (p p) (h hq) (tail tq)))
           :in-theory (disable encoded-name hash-name))))
