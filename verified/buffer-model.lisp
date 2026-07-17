;;;; verified/buffer-model.lisp -- Formal buffer model + well-formedness (SPEC-VK VK-1).
;;;;
;;;; One source of truth (SPEC-VK Constraint 2): this same file is certified by
;;;; ACL2 (scripts/run-proofs.sh) AND loaded verbatim into the Lem SBCL image
;;;; through verified/shim.lisp, where `wf-buffer' doubles as a runtime
;;;; well-formedness assertion.
;;;;
;;;; REPRESENTATION (from the V1 kernel design brief -- ACL2 characters are only
;;;; 8-bit, so text is NEVER an ACL2 string/char-list here):
;;;;   codepoint : a natural number.  A line codepoint additionally excludes 10
;;;;               (LF): newlines separate lines, they never live inside one.
;;;;   line      : a true-list of line-codepoints (no 10).
;;;;   point     : (list id linum charpos kind)
;;;;                 id      natural, unique within the buffer
;;;;                 linum   1-based line number, 1 <= linum <= (len lines)
;;;;                 charpos 0-based column, 0 <= charpos <= (len of its line)
;;;;                 kind    :left-inserting or :right-inserting.
;;;;               ONLY registered points are modelled.  Production :temporary
;;;;               points are unregistered and explicitly invalid across edits
;;;;               (src/buffer/internal/point.lisp initialize-point pushes only
;;;;               non-temporary points onto buffer-points), so they are out of
;;;;               the model; the conformance mapper compares registered points
;;;;               only.
;;;;   buffer    : (list lines points tick)
;;;;               There is NO nlines field: nlines is derived as (len lines).
;;;;               (Deviation from the SPEC-VK VK-1 model sketch, which lists an
;;;;               nlines component -- recorded in verified/README.md and the
;;;;               agent notes.  The conformance mapper asserts production's
;;;;               cached buffer-nlines equals (len model-lines), pinning the
;;;;               same invariant with fewer moving parts.)
;;;;
;;;; Three DISTINGUISHED point ids are required present, mirroring production's
;;;; buffer-start-point / buffer-end-point / buffer-point:
;;;;   0 = start-point : linum = 1
;;;;   1 = end-point   : linum = (len lines) AND charpos = length of the last line
;;;;   2 = buffer-point.
;;;;
;;;; `wf-buffer' captures every structural invariant check-buffer-corruption
;;;; enforces today (src/buffer/internal/check-corruption.lisp), translated to
;;;; this representation:
;;;;   * lines is a list of nat-lists with no 10, always >= 1 line;
;;;;   * every point is well-shaped, in bounds, with a valid kind;
;;;;   * point ids are pairwise-distinct naturals;
;;;;   * the three distinguished ids are present with the start/end invariants;
;;;;   * every point lies between start-point and end-point (the point<= loop);
;;;;   * tick is an integer.
;;;; check-buffer-corruption's doubly-linked-list / line-points bookkeeping
;;;; (line.prev.next = line, point.linum = its line's number, buffer-points =
;;;; union of line-points) is structurally automatic in this representation: a
;;;; point's line membership IS its linum, so those checks collapse to the
;;;; linum-in-range check.
;;;;
;;;; EXEC PATH uses only CL homonyms + the shim whitelist {natp, len, true-listp}
;;;; (verified/shim.lisp).  No std/ function appears in exec-reachable code;
;;;; std/ books, if included, are lemma libraries for proofs only.

(in-package "ACL2")

;;; ---------------------------------------------------------------------------
;;; Point accessors and shape
;;; ---------------------------------------------------------------------------

(defun pt-id (p) (car p))
(defun pt-linum (p) (car (cdr p)))
(defun pt-charpos (p) (car (cdr (cdr p))))
(defun pt-kind (p) (car (cdr (cdr (cdr p)))))

(defun kindp (k)
  (or (eq k :left-inserting)
      (eq k :right-inserting)))

(defun pointp (p)
  (and (true-listp p)
       (= (len p) 4)
       (natp (pt-id p))
       (natp (pt-linum p))
       (natp (pt-charpos p))
       (kindp (pt-kind p))))

;;; ---------------------------------------------------------------------------
;;; Lines: nat-lists without 10, list of such
;;; ---------------------------------------------------------------------------

(defun line-codepoint-p (x)
  (and (natp x)
       (not (= x 10))))

(defun linep (l)
  (if (atom l)
      (null l)
      (and (line-codepoint-p (car l))
           (linep (cdr l)))))

(defun line-listp (ls)
  (if (atom ls)
      (null ls)
      (and (linep (car ls))
           (line-listp (cdr ls)))))

;; 0-based indexed line; total (returns nil when out of range).  Avoids ACL2
;; `nth'/`zp' so the exec path stays on CL homonyms.
(defun nth-line (n lines)
  (declare (xargs :measure (acl2-count lines)))
  (if (consp lines)
      (if (<= n 0)
          (car lines)
          (nth-line (- n 1) (cdr lines)))
      nil))

(defun last-line (lines)
  (if (consp (cdr lines))
      (last-line (cdr lines))
      (car lines)))

;;; ---------------------------------------------------------------------------
;;; Buffer accessors and shape
;;; ---------------------------------------------------------------------------

(defun buf-lines (b) (car b))
(defun buf-points (b) (car (cdr b)))
(defun buf-tick (b) (car (cdr (cdr b))))

(defun buffer-shape-p (b)
  (and (true-listp b)
       (= (len b) 3)))

;;; ---------------------------------------------------------------------------
;;; Point-set invariants
;;; ---------------------------------------------------------------------------

(defun points-listp (points)
  (if (atom points)
      (null points)
      (and (pointp (car points))
           (points-listp (cdr points)))))

(defun point-in-bounds-p (p lines)
  (and (<= 1 (pt-linum p))
       (<= (pt-linum p) (len lines))
       (<= (pt-charpos p) (len (nth-line (- (pt-linum p) 1) lines)))))

(defun points-in-bounds-p (points lines)
  (if (atom points)
      t
      (and (point-in-bounds-p (car points) lines)
           (points-in-bounds-p (cdr points) lines))))

;; Membership by value; used by reuse lemmas (find-point returns a member).
(defun in-points (p points)
  (if (atom points)
      nil
      (or (equal p (car points))
          (in-points p (cdr points)))))

(defun member-nat (x lst)
  (if (atom lst)
      nil
      (or (equal x (car lst))
          (member-nat x (cdr lst)))))

(defun ids-of (points)
  (if (atom points)
      nil
      (cons (pt-id (car points))
            (ids-of (cdr points)))))

(defun distinct-nats (lst)
  (if (atom lst)
      t
      (and (not (member-nat (car lst) (cdr lst)))
           (distinct-nats (cdr lst)))))

(defun distinct-ids (points)
  (distinct-nats (ids-of points)))

;; The find-first-by-id lookup for the distinguished points.
(defun find-point (id points)
  (cond ((atom points) nil)
        ((equal (pt-id (car points)) id) (car points))
        (t (find-point id (cdr points)))))

;; Lexicographic (linum, charpos) order -- production point<= .
(defun pt-<= (p q)
  (or (< (pt-linum p) (pt-linum q))
      (and (= (pt-linum p) (pt-linum q))
           (<= (pt-charpos p) (pt-charpos q)))))

(defun points-bounded-by (sp ep points)
  (if (atom points)
      t
      (and (pt-<= sp (car points))
           (pt-<= (car points) ep)
           (points-bounded-by sp ep (cdr points)))))

;;; ---------------------------------------------------------------------------
;;; Distinguished-point invariants (start=0, end=1, buffer-point=2)
;;; ---------------------------------------------------------------------------

(defun wf-distinguished (points lines)
  (and (find-point 0 points)                       ; start present
       (find-point 1 points)                       ; end present
       (find-point 2 points)                       ; buffer-point present
       (= (pt-linum (find-point 0 points)) 1)      ; start on line 1
       (= (pt-linum (find-point 1 points))         ; end on last line
          (len lines))
       (= (pt-charpos (find-point 1 points))       ; end at end of last line
          (len (last-line lines)))
       ;; start-point <= every point <= end-point  (the point<= loop)
       (points-bounded-by (find-point 0 points)
                          (find-point 1 points)
                          points)))

;;; ---------------------------------------------------------------------------
;;; wf-buffer -- the executable well-formedness predicate
;;; ---------------------------------------------------------------------------

;; The conjuncts are ordered so each guards the next in-image: shape before
;; accessors dereference, points-listp before point fields are read, etc.
(defun wf-buffer (b)
  (and (buffer-shape-p b)
       (line-listp (buf-lines b))
       (<= 1 (len (buf-lines b)))
       (points-listp (buf-points b))
       (points-in-bounds-p (buf-points b) (buf-lines b))
       (distinct-ids (buf-points b))
       (integerp (buf-tick b))
       (wf-distinguished (buf-points b) (buf-lines b))))

;;; ---------------------------------------------------------------------------
;;; Canonical empty buffer (production `make-buffer' initial state)
;;; ---------------------------------------------------------------------------

;; One empty line; start(1,0,:right-inserting), end(1,0,:left-inserting),
;; buffer-point(1,0,:left-inserting); tick 0.  (Kinds match production
;; make-buffer-start-point/-end-point/-point.)
(defun empty-buffer ()
  (list (list nil)
        (list (list 0 1 0 :right-inserting)
              (list 1 1 0 :left-inserting)
              (list 2 1 0 :left-inserting))
        0))

;;; ---------------------------------------------------------------------------
;;; Theorems
;;; ---------------------------------------------------------------------------

;; VK-1 primary obligation: the canonical empty buffer is well-formed.
(defthm wf-buffer-of-empty-buffer
  (wf-buffer (empty-buffer)))

;; Reuse lemmas for VK-2: wf-buffer decomposed into its component invariants,
;; stated so downstream edit-preservation proofs can pull each one out.
(defthm wf-buffer-implies-buffer-shape
  (implies (wf-buffer b)
           (buffer-shape-p b)))

(defthm wf-buffer-implies-line-listp
  (implies (wf-buffer b)
           (line-listp (buf-lines b))))

(defthm wf-buffer-implies-lines-nonempty
  (implies (wf-buffer b)
           (<= 1 (len (buf-lines b)))))

(defthm wf-buffer-implies-points-listp
  (implies (wf-buffer b)
           (points-listp (buf-points b))))

(defthm wf-buffer-implies-points-in-bounds
  (implies (wf-buffer b)
           (points-in-bounds-p (buf-points b) (buf-lines b))))

(defthm wf-buffer-implies-distinct-ids
  (implies (wf-buffer b)
           (distinct-ids (buf-points b))))

(defthm wf-buffer-implies-integerp-tick
  (implies (wf-buffer b)
           (integerp (buf-tick b))))

(defthm wf-buffer-implies-wf-distinguished
  (implies (wf-buffer b)
           (wf-distinguished (buf-points b) (buf-lines b))))

;; Distinguished points are present under wf (extracted for VK-2 convenience).
(defthm wf-buffer-start-point-present
  (implies (wf-buffer b)
           (find-point 0 (buf-points b))))

(defthm wf-buffer-end-point-present
  (implies (wf-buffer b)
           (find-point 1 (buf-points b))))

(defthm wf-buffer-buffer-point-present
  (implies (wf-buffer b)
           (find-point 2 (buf-points b))))

;; find-point returns a genuine member with the requested id -- lets VK-2 push
;; a distinguished lookup through the points-in-bounds invariant.
(defthm find-point-in-points
  (implies (find-point id points)
           (in-points (find-point id points) points)))

(defthm pt-id-of-find-point
  (implies (find-point id points)
           (equal (pt-id (find-point id points)) id)))

;; The workhorse reuse lemma: any member of an in-bounds point-set is itself in
;; bounds.  VK-2 uses this to know every relocated point stays addressable.
(defthm point-in-bounds-of-in-points
  (implies (and (points-in-bounds-p points lines)
                (in-points p points))
           (point-in-bounds-p p lines)))

;; Corollary chaining the two above: the end-point of a wf buffer is in bounds.
(defthm wf-buffer-end-point-in-bounds
  (implies (wf-buffer b)
           (point-in-bounds-p (find-point 1 (buf-points b))
                              (buf-lines b))))
