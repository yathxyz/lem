;;;; verified/undo.lisp -- Undo/redo kernel + tick semantics (SPEC-VK VK-3).
;;;;
;;;; One source of truth (SPEC-VK Constraint 2): this same file is certified by
;;;; ACL2 (scripts/run-proofs.sh) AND loaded verbatim into the Lem SBCL image
;;;; through verified/shim.lisp.
;;;;
;;;; This book models production's undo machinery
;;;; (src/buffer/internal/undo.lisp, src/buffer/internal/edit.lisp) as pure
;;;; data, on top of the VK-1 buffer model and the VK-2 edit primitives.
;;;;
;;;; EDIT RECORD (production `edit' struct, src/buffer/internal/edit.lisp:6-14):
;;;;   (list kind position payload)
;;;;     kind     : :insert-string or :delete-string
;;;;     position : a 1-based ABSOLUTE buffer position (production position is an
;;;;                (integer 1 *) -- position-at-point); undo converts it back to
;;;;                (linum charpos) with k-point-at-position at apply time.
;;;;     payload  : the codepoint list inserted / actually deleted.  For a delete
;;;;                the payload is the TEXT ACTUALLY REMOVED (mv-nth 1 of k-delete
;;;;                -- possibly shorter than the requested N when the delete runs
;;;;                off the buffer end), exactly as production records the string
;;;;                returned by delete-char/point.  Recording the real removed
;;;;                text is what makes insert<->delete exact content inverses.
;;;;
;;;; SESSION STATE = (list buffer history redo)
;;;;   buffer  : a VK-1/VK-2 buffer (list lines points tick); tick is the
;;;;             production modified counter (buffer-%modified-p).
;;;;   history : a list of (edit | :separator), CAR = top of stack.  Production
;;;;             keeps this in a fill-pointer vector with the top at the end;
;;;;             CAR-is-top is the same LIFO discipline (vector-push-extend = cons,
;;;;             vector-pop = car/cdr).
;;;;   redo    : a list of (edit | :separator), CAR = top (production redo-stack
;;;;             is already a CAR-is-top list).
;;;;
;;;; TICK ACCOUNTING (production buffer-modify, undo.lisp:47-53): a buffer
;;;; mutation changes tick by +1 in :edit / :redo mode and -1 in :undo mode --
;;;; the SIGN IS SET BY THE MODE, NOT by insert-vs-delete.  VK-2's k-insert /
;;;; k-delete always bump +1 (they were written for :edit mode), so this book
;;;; separates the content/point transform from the tick delta: apply-edit-content
;;;; carries the tick THROUGH unchanged and each session op sets the tick delta
;;;; explicitly (buf-with-tick), reproducing the mode-driven +-1 exactly.
;;;;
;;;; INHIBITED EDITS (production *inhibit-undo*, buffer-insert.lisp:186-220): an
;;;; inhibited edit mutates the buffer (tick +1, via buffer-modify) but is NOT
;;;; recorded; instead it recomputes every STORED position by compute-edit-offset
;;;; (recompute-undo-position-offset, undo.lisp:116-122).  k-recompute-offsets
;;;; transcribes that, reusing VK-2's k-shift-position-insert / -delete.
;;;;
;;;; EXEC PATH uses only CL homonyms + the shim whitelist {natp len true-listp}
;;;; + mv/mv-let + functions from buffer-model.lisp / buffer-edit.lisp / this
;;;; book.  std/ community books, when included, are proof-only local libraries.

(in-package "ACL2")

(include-book "buffer-edit")

(local (include-book "arithmetic/top-with-meta" :dir :system))

;;; ===========================================================================
;;; Edit records
;;; ===========================================================================

(defun edit-knd (e) (car e))
(defun edit-pos (e) (car (cdr e)))
(defun edit-pay (e) (car (cdr (cdr e))))

(defun mk-edit (kind position payload)
  (list kind position payload))

(defun edit-kindp (k)
  (or (eq k :insert-string)
      (eq k :delete-string)))

(defun editp (e)
  (and (true-listp e)
       (= (len e) 3)
       (edit-kindp (edit-knd e))
       (natp (edit-pos e))
       (<= 1 (edit-pos e))
       (payloadp (edit-pay e))))

;; Invert an edit: swap kind, keep absolute position and payload.  Production
;; apply-inverse-edit (edit.lisp:27-38) turns an insert into a delete of the
;; same string at the same position and vice versa; the buffer operation then
;; re-derives the identical position/string, so edit-invert is faithful under
;; the round-trip (no intervening edit) hypotheses of the theorems.
(defun edit-invert (e)
  (mk-edit (if (eq (edit-knd e) :insert-string)
               :delete-string
               :insert-string)
           (edit-pos e)
           (edit-pay e)))

;;; ===========================================================================
;;; Session accessors
;;; ===========================================================================

(defun sn-buffer (s) (car s))
(defun sn-history (s) (car (cdr s)))
(defun sn-redo (s) (car (cdr (cdr s))))

(defun mk-session (buffer history redo)
  (list buffer history redo))

(defun buf-with-tick (b tk)
  (list (buf-lines b) (buf-points b) tk))

;; A history/redo element list: each element an edit or :separator.
(defun histp (h)
  (if (atom h)
      (null h)
      (and (or (eq (car h) :separator)
               (editp (car h)))
           (histp (cdr h)))))

;;; ===========================================================================
;;; Content application (tick carried through unchanged)
;;; ===========================================================================

;; Apply edit E to buffer B (content + points), using k-insert / k-delete
;; verbatim.  Converts the stored absolute position to (linum charpos) with
;; k-point-at-position, exactly as production apply-edit does via
;; move-to-position (basic.lisp:389-399) + insert-string/point / delete-char/point.
;; The tick delta of k-insert / k-delete is +1, which is EXACTLY production's
;; :edit / :redo-mode buffer-modify; only the :undo path needs a correction,
;; applied by undo-loop via buf-with-tick (see below).
(defun apply-edit-content (b e)
  (mv-let (linum charpos)
      (k-point-at-position (buf-lines b) (edit-pos e))
    (if (eq (edit-knd e) :insert-string)
        (k-insert b linum charpos (edit-pay e))
        (mv-let (b2 deleted)
            (k-delete b linum charpos (len (edit-pay e)))
          (declare (ignore deleted))
          b2))))

;;; ===========================================================================
;;; Recording a user edit (:edit mode: push, clear redo, tick +1)
;;; ===========================================================================

;; k-do-insert / k-do-delete: a user edit in :edit mode.  Production
;; insert-string/point / delete-char/point mutate the buffer (buffer-modify
;; tick +1) and the :around method records the edit via push-undo :edit, which
;; pushes onto edit-history AND clears the redo stack (undo.lisp:61-70).

(defun k-do-insert (s position payload)
  (let ((b (sn-buffer s)))
    (mv-let (linum charpos)
        (k-point-at-position (buf-lines b) position)
      (mk-session (k-insert b linum charpos payload)     ; k-insert bumps tick +1
                  (cons (mk-edit :insert-string position payload)
                        (sn-history s))
                  nil))))

(defun k-do-delete (s position n)
  (let ((b (sn-buffer s)))
    (mv-let (linum charpos)
        (k-point-at-position (buf-lines b) position)
      (mv-let (b2 deleted)
          (k-delete b linum charpos n)                   ; k-delete bumps tick +1
        (mk-session b2
                    (cons (list :delete-string position deleted)
                          (sn-history s))
                    nil)))))

;;; ===========================================================================
;;; Undo boundary (buffer-undo-boundary, undo.lisp:42-45): push :separator
;;; unless the top is already a separator (dedup).
;;; ===========================================================================

(defun k-boundary (s)
  (let ((h (sn-history s)))
    (mk-session (sn-buffer s)
                (if (and (consp h) (eq (car h) :separator))
                    h
                    (cons :separator h))
                (sn-redo s))))

;;; ===========================================================================
;;; Undo group (buffer-undo, undo.lisp:81-93)
;;; ===========================================================================

;; The pop-and-apply loop: pop edits off HISTORY, apply each inverse to the
;; buffer under :undo mode (content transform + tick -1) and push the inverse
;; onto REDO (production push-undo :undo), until a :separator is popped (it is
;; consumed and the loop stops, buffer-undo-1) or HISTORY empties.  Returns
;; (mv buffer' history' redo' applied?) where applied? records whether at least
;; one real edit was applied (production's result0).
(defun undo-loop (buffer history redo)
  (declare (xargs :measure (acl2-count history)))
  (cond ((atom history)
         (mv buffer history redo nil))
        ((eq (car history) :separator)
         (mv buffer (cdr history) redo nil))
        (t
         (let* ((e (car history))
                (inv (edit-invert e))
                ;; :undo mode: content op bumps +1, but buffer-modify decrements,
                ;; so the net tick delta is -1 (buf-with-tick corrects +1 -> -1).
                (buffer1 (buf-with-tick (apply-edit-content buffer inv)
                                        (- (buf-tick buffer) 1)))
                (redo1 (cons inv redo)))
           (mv-let (b2 h2 r2 app2)
               (undo-loop buffer1 (cdr history) redo1)
             (declare (ignore app2))
             (mv b2 h2 r2 t))))))

(defun k-undo-group (s)
  (let* ((buffer (sn-buffer s))
         (history (sn-history s))
         (redo (sn-redo s))
         (redo1 (cons :separator redo))
         (history1 (if (and (consp history) (eq (car history) :separator))
                       (cdr history)
                       history)))
    (mv-let (b2 h2 r2 applied)
        (undo-loop buffer history1 redo1)
      (if applied
          (mk-session b2 h2 r2)
          ;; nothing applied: pop the separator we pushed onto redo
          (mk-session b2 h2 (cdr r2))))))

;;; ===========================================================================
;;; Redo group (buffer-redo, undo.lisp:103-114)
;;; ===========================================================================

;; Symmetric to undo-loop: pop items off REDO, apply each inverse under :redo
;; mode (content transform + tick +1), push the inverse onto HISTORY, until a
;; :separator is popped or REDO empties.
(defun redo-loop (buffer history redo)
  (declare (xargs :measure (acl2-count redo)))
  (cond ((atom redo)
         (mv buffer history redo nil))
        ((eq (car redo) :separator)
         (mv buffer history (cdr redo) nil))
        (t
         (let* ((e (car redo))
                (inv (edit-invert e))
                ;; :redo mode: content op bumps +1, exactly buffer-modify's +1,
                ;; so no correction is needed.
                (buffer1 (apply-edit-content buffer inv))
                (history1 (cons inv history)))
           (mv-let (b2 h2 r2 app2)
               (redo-loop buffer1 history1 (cdr redo))
             (declare (ignore app2))
             (mv b2 h2 r2 t))))))

(defun k-redo-group (s)
  (let* ((buffer (sn-buffer s))
         (history (sn-history s))
         (redo (sn-redo s))
         (history1 (cons :separator history)))
    (mv-let (b2 h2 r2 applied)
        (redo-loop buffer history1 redo)
      (if applied
          (mk-session b2 h2 r2)
          ;; nothing applied: pop the separator we pushed onto history
          (mk-session b2 (cdr h2) r2)))))

;;; ===========================================================================
;;; Inhibited edits (*inhibit-undo*): mutate + tick +1, DON'T record, but
;;; recompute every stored position (recompute-undo-position-offset +
;;; compute-edit-offset, undo.lisp:116-122 / edit.lisp:40-51).
;;; ===========================================================================

;; Shift one stored edit's position across an untracked edit of the given kind,
;; length and position -- compute-edit-offset's two branches, reusing VK-2's
;; k-shift-position-insert / k-shift-position-delete.
(defun recompute-edit-offset (stored kind position length)
  (if (eq stored :separator)
      stored
      (mk-edit (edit-knd stored)
               (if (eq kind :insert-string)
                   (k-shift-position-insert (edit-pos stored) position length)
                   (k-shift-position-delete (edit-pos stored) position length))
               (edit-pay stored))))

(defun recompute-hist-offsets (h kind position length)
  (if (atom h)
      nil
      (cons (recompute-edit-offset (car h) kind position length)
            (recompute-hist-offsets (cdr h) kind position length))))

(defun k-recompute-offsets (s kind position length)
  (mk-session (sn-buffer s)
              (recompute-hist-offsets (sn-history s) kind position length)
              (recompute-hist-offsets (sn-redo s) kind position length)))

(defun k-do-inhibited-insert (s position payload)
  (let* ((b (sn-buffer s))
         (s1 (mv-let (linum charpos)
                 (k-point-at-position (buf-lines b) position)
               (mk-session (k-insert b linum charpos payload)  ; tick +1
                           (sn-history s)
                           (sn-redo s)))))
    (k-recompute-offsets s1 :insert-string position (len payload))))

(defun k-do-inhibited-delete (s position n)
  (let ((b (sn-buffer s)))
    (mv-let (linum charpos)
        (k-point-at-position (buf-lines b) position)
      (mv-let (b2 deleted)
          (k-delete b linum charpos n)                        ; tick +1
        (k-recompute-offsets
         (mk-session b2
                     (sn-history s)
                     (sn-redo s))
         :delete-string position (len deleted))))))

;;; ===========================================================================
;;; Position stability: an insert at (linum,charpos) does not change the
;;; position<->point mapping for the inserted location itself.
;;; ===========================================================================

;; flat-len-before only inspects the first J lines, so it ignores an append
;; tail once J reaches the prefix length.
(defthm flat-len-before-of-append-le
  (implies (and (natp j) (true-listp a) (<= j (len a)))
           (equal (flat-len-before (append a b) j)
                  (flat-len-before a j)))
  :hints (("Goal" :induct (flat-len-before a j))))

(defthm flat-len-before-of-k-take
  (implies (natp j)
           (equal (flat-len-before (k-take j l) j)
                  (flat-len-before l j)))
  :hints (("Goal" :induct (flat-len-before l j))))

;; The first (linum-1) lines are untouched by insert-into-lines, so the flat
;; length before the edit line is unchanged; hence k-position is unchanged.
(defthm flat-len-before-of-insert-into-lines
  (implies (and (line-listp lines)
                (natp linum) (<= 1 linum) (<= linum (len lines)))
           (equal (flat-len-before (insert-into-lines lines linum charpos payload)
                                   (+ -1 linum))
                  (flat-len-before lines (+ -1 linum))))
  :hints (("Goal" :in-theory (disable make-inserted-lines))))

(defthm k-position-of-insert-into-lines
  (implies (and (line-listp lines)
                (natp linum) (<= 1 linum) (<= linum (len lines)))
           (equal (k-position (insert-into-lines lines linum charpos payload)
                              linum charpos)
                  (k-position lines linum charpos))))

;; The edit line after the insert is at least CHARPOS long (it begins with the
;; length-CHARPOS prefix), so CHARPOS remains a valid column there.
(defthm charpos-bound-on-inserted-line
  (implies (and (line-listp lines)
                (natp linum) (<= 1 linum) (<= linum (len lines))
                (natp charpos)
                (<= charpos (len (nth-line (+ -1 linum) lines))))
           (<= charpos
               (len (nth-line (+ -1 linum)
                              (insert-into-lines lines linum charpos payload)))))
  :hints (("Goal" :in-theory (disable make-inserted-lines))))

(defthm len-of-insert-into-lines-linear
  (implies (and (line-listp lines)
                (natp linum) (<= 1 linum) (<= linum (len lines)))
           (<= (len lines)
               (len (insert-into-lines lines linum charpos payload))))
  :rule-classes :linear)

;; The crux: converting the recorded absolute position back to a point in the
;; POST-INSERT buffer lands exactly on the original (linum,charpos) -- so the
;; undo delete hits precisely the inserted region.
(defthm k-point-at-position-of-inserted
  (implies (and (line-listp lines) (consp lines) (payloadp payload)
                (natp linum) (<= 1 linum) (<= linum (len lines))
                (natp charpos)
                (<= charpos (len (nth-line (+ -1 linum) lines))))
           (and (equal (mv-nth 0 (k-point-at-position
                                  (insert-into-lines lines linum charpos payload)
                                  (k-position lines linum charpos)))
                       linum)
                (equal (mv-nth 1 (k-point-at-position
                                  (insert-into-lines lines linum charpos payload)
                                  (k-position lines linum charpos)))
                       charpos)))
  :hints (("Goal"
           :do-not-induct t
           :in-theory (disable k-position insert-into-lines
                               k-point-at-position-of-k-position)
           :use ((:instance k-point-at-position-of-k-position
                            (lines (insert-into-lines lines linum charpos payload)))
                 (:instance k-position-of-insert-into-lines)
                 (:instance charpos-bound-on-inserted-line)
                 (:instance len-of-insert-into-lines-linear)
                 (:instance line-listp-of-insert-into-lines)))))

;;; ===========================================================================
;;; Obligation 1 (insert case) + tick round-trip (the sound tick fact):
;;; undoing a single recorded INSERT restores lines, points AND tick exactly.
;;; ===========================================================================

(defthm buf-lines-of-buf-with-tick
  (equal (buf-lines (buf-with-tick b tk)) (buf-lines b)))
(defthm buf-points-of-buf-with-tick
  (equal (buf-points (buf-with-tick b tk)) (buf-points b)))
(defthm buf-tick-of-buf-with-tick
  (equal (buf-tick (buf-with-tick b tk)) tk))

;; Field accessors of k-insert (kept as rewrites so k-insert can stay closed --
;; letting k-delete-of-k-insert match the literal (k-delete (k-insert ...))).
(defthm buf-lines-of-k-insert
  (equal (buf-lines (k-insert b linum charpos payload))
         (insert-into-lines (buf-lines b) linum charpos payload)))
(defthm buf-points-of-k-insert
  (equal (buf-points (k-insert b linum charpos payload))
         (shift-points-insert (buf-points b) linum charpos
                              (- (len (split-lf payload)) 1)
                              (len (last-seg (split-lf payload))))))
(defthm buf-tick-of-k-insert
  (equal (buf-tick (k-insert b linum charpos payload))
         (+ 1 (buf-tick b))))

;; A shape-3 buffer is its own (lines points tick) reconstruction.
(defthm buffer-shape-reconstruction
  (implies (buffer-shape-p b)
           (equal (list (buf-lines b) (buf-points b) (buf-tick b)) b)))

;; apply-edit-content of the inverse (a delete at the recorded position of
;; exactly the inserted payload) applied to the post-insert buffer restores
;; lines and points; its tick is the post-insert tick (+2 over the original),
;; corrected to -1 net by undo-loop's buf-with-tick.
(defthm apply-edit-content-of-insert-inverse
  (implies (and (wf-buffer b)
                (edit-locp b linum charpos)
                (payloadp payload))
           (equal (apply-edit-content
                   (k-insert b linum charpos payload)
                   (list :delete-string
                            (k-position (buf-lines b) linum charpos)
                            payload))
                  (list (buf-lines b) (buf-points b) (+ 2 (buf-tick b)))))
  :hints (("Goal"
           :do-not-induct t
           :in-theory (disable buf-lines buf-points buf-tick
                               k-insert k-delete k-position insert-into-lines
                               shift-points-insert k-point-at-position)
           :use ((:instance k-point-at-position-of-inserted
                            (lines (buf-lines b)))
                 (:instance k-delete-of-k-insert)))))

;; The undo of a single recorded insert (history top = the edit, then a
;; separator) restores the buffer that existed before the insert: lines,
;; registered points, and tick all exactly.  Tick restoration is the SOUND
;; tick fact -- the net signed edit-application count returns to zero, so the
;; modified counter is back where it started (contrast the REFUTED biconditional
;; documented in verified/README.md, which no theorem claims).
(defthm k-undo-group-of-k-do-insert
  (implies (and (wf-buffer b)
                (edit-locp b linum charpos)
                (payloadp payload))
           (equal (sn-buffer
                   (k-undo-group
                    (k-do-insert (mk-session b (cons :separator hst) rdo)
                                 (k-position (buf-lines b) linum charpos)
                                 payload)))
                  b))
  :hints (("Goal"
           :do-not-induct t
           :in-theory (disable buf-tick k-insert k-delete k-position
                               insert-into-lines shift-points-insert
                               k-point-at-position apply-edit-content
                               buffer-shape-p)
           :use ((:instance apply-edit-content-of-insert-inverse)
                 (:instance buf-tick-of-k-insert)
                 (:instance buffer-shape-reconstruction)
                 (:instance wf-buffer-implies-buffer-shape)))))

;;; ===========================================================================
;;; Obligation 2: redo o undo = id (no intervening edit), single insert.
;;; ===========================================================================

;; apply-edit-content of an INSERT edit recorded at position P = k-position of
;; (linum,charpos) is exactly k-insert at (linum,charpos): the position->point
;; round trip (VK-2 k-point-at-position-of-k-position) recovers the coordinates.
(defthm apply-edit-content-of-insert-edit
  (implies (and (line-listp (buf-lines b)) (consp (buf-lines b))
                (natp linum) (<= 1 linum) (<= linum (len (buf-lines b)))
                (natp charpos)
                (<= charpos (len (nth-line (+ -1 linum) (buf-lines b)))))
           (equal (apply-edit-content
                   b
                   (list :insert-string
                         (k-position (buf-lines b) linum charpos)
                         payload))
                  (k-insert b linum charpos payload)))
  :hints (("Goal"
           :do-not-induct t
           :in-theory (disable k-insert k-position k-point-at-position
                               k-point-at-position-of-k-position)
           :use ((:instance k-point-at-position-of-k-position
                            (lines (buf-lines b)))))))

;; Redoing an undone insert re-applies the identical insert and restores the
;; full session -- buffer, history AND redo stack -- to its pre-undo state:
;; k-redo-group o k-undo-group is the identity on a freshly recorded insert.
;; (No intervening edit: the redo stack still holds the inverse the undo left.)
(defthm k-redo-group-of-k-undo-group-of-k-do-insert
  (implies (and (wf-buffer b)
                (edit-locp b linum charpos)
                (payloadp payload))
           (equal (k-redo-group
                   (k-undo-group
                    (k-do-insert (mk-session b (cons :separator hst) rdo)
                                 (k-position (buf-lines b) linum charpos)
                                 payload)))
                  (k-do-insert (mk-session b (cons :separator hst) rdo)
                               (k-position (buf-lines b) linum charpos)
                               payload)))
  :hints (("Goal"
           :do-not-induct t
           :in-theory (disable buf-tick k-insert k-delete k-position
                               insert-into-lines shift-points-insert
                               k-point-at-position apply-edit-content
                               buffer-shape-p)
           :use ((:instance apply-edit-content-of-insert-inverse)
                 (:instance apply-edit-content-of-insert-edit)
                 (:instance buf-tick-of-k-insert)
                 (:instance buffer-shape-reconstruction)
                 (:instance wf-buffer-implies-buffer-shape)
                 (:instance wf-buffer-implies-line-listp)
                 (:instance wf-buffer-implies-lines-nonempty)))))

;;; ===========================================================================
;;; Obligation 4 (history validity): recorded positions are in bounds.
;;;
;;; The full cross-op invariant ("every stored position stays in bounds after
;;; ANY interleaving of edits/undos/redos/inhibited edits") is REFUTED for the
;;; inhibited path -- see verified/README.md "VK-3 history-validity decision"
;;; and the tick-probe c1 reproducer: an inhibited edit shrinks the buffer and
;;; recomputes stored positions consistently with the shrunk buffer, but undo
;;; then applies the group's edits sequentially and an earlier-applied undo can
;;; shrink the buffer below a later stored position (production move-to-position
;;; returns NIL and the edit is mis-placed).  What IS soundly true, and proved
;;; here, is the invariant's foundation: every position RECORDED by a user edit
;;; is a valid buffer position, so it is in bounds at record time and (for
;;; inhibition-free histories, where undo exactly reverses the recording order)
;;; stays in bounds through undo.
;;; ===========================================================================

;; The flat length up to line J plus that line's own length never exceeds the
;; whole flattened length (there is always at least the inter-line newlines to
;; spare).
(defthm flat-prefix-plus-line-le-flatten
  (implies (and (natp j) (< j (len lines)) (line-listp lines))
           (<= (+ (flat-len-before lines j) (len (nth-line j lines)))
               (len (k-flatten lines))))
  :rule-classes :linear
  :hints (("Goal" :induct (flat-len-before lines j))))

;; A recorded absolute position is a valid 1-based buffer position: between 1
;; and (char-count + 1).  char-count = (len (k-flatten lines)).  Hence
;; k-point-at-position never runs off the buffer and the undo apply of a
;; freshly recorded edit addresses a real location.
(defthm k-position-in-bounds
  (implies (and (line-listp (buf-lines b)) (consp (buf-lines b))
                (edit-locp b linum charpos))
           (and (<= 1 (k-position (buf-lines b) linum charpos))
                (<= (k-position (buf-lines b) linum charpos)
                    (+ 1 (len (k-flatten (buf-lines b)))))))
  :rule-classes :linear
  :hints (("Goal"
           :do-not-induct t
           :in-theory (disable k-flatten flat-len-before)
           :use ((:instance flat-prefix-plus-line-le-flatten
                            (lines (buf-lines b)) (j (+ -1 linum)))))))
