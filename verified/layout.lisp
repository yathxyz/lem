;;;; verified/layout.lisp -- Line layout kernel: wrapping & clipping (SPEC-VK VK-11).
;;;;
;;;; One source of truth (SPEC-VK Constraint 2): this same file is certified by
;;;; ACL2 (scripts/run-proofs.sh) AND loadable verbatim into the Lem SBCL image
;;;; through verified/shim.lisp.  It transcribes the two pure algorithms of
;;;; src/display/physical-line.lisp:
;;;;
;;;;   `k-wrap-row'/`k-wrap'  <->  separate-objects-by-width (+ its inner
;;;;                               explode-object halving) and the row loop of
;;;;                               redraw-logical-line-when-line-wrapping;
;;;;   `k-clip'/`k-clip-chars' <-> clip-objects-to-display-range;
;;;;   `k-scroll-adjust'       <-> the horizontal-scroll-start adjustment of
;;;;                               redraw-logical-line-when-horizontal-scroll.
;;;;
;;;; REPRESENTATION.  A display object is
;;;;     (:text codes widths tag)   -- text run: codepoint list + ALIGNED
;;;;                                   per-char width list (naturals; the
;;;;                                   ncurses column widths), TAG an opaque
;;;;                                   payload the kernel carries verbatim so an
;;;;                                   adapter can map rows back to CLOS objects
;;;;                                   (attribute/type/identity);
;;;;     (:opaque width tag)        -- unbreakable non-text object (void /
;;;;                                   eol-cursor / extend-to-eol / image; all
;;;;                                   width 0 on ncurses).
;;;; Codepoints are naturals, never ACL2 strings/characters (8-bit only).
;;;;
;;;; TRANSCRIPTION FIDELITY (production = src/display/physical-line.lisp):
;;;;   * k-wrap-row mirrors separate-objects-by-width branch-for-branch: a TEXT
;;;;     object whose width would reach the view width (<=) is halved
;;;;     (explode-object; split point (floor len 2)) and re-tried; once a
;;;;     single-codepoint object still does not fit it is pushed back and the
;;;;     row is emitted; NON-text objects are placed unconditionally (production
;;;;     wraps only on `(typep object 'text-object)').
;;;;   * The wrap-line-character marker production pushes onto a wrapped row is
;;;;     ABSTRACTED AS THE ROW BOUNDARY (design brief): a row was wrapped iff
;;;;     the second value (rest) is non-nil; the adapter/test re-attaches the
;;;;     marker there.  Kernel rows therefore never contain marker objects.
;;;;   * k-wrap iterates k-wrap-row under a FUEL bound exactly as production's
;;;;     redraw loop is bounded by the window height (on ncurses every row has
;;;;     height 1, so fuel = row budget is production's own cutoff, not an
;;;;     approximation).  Production makes NO progress on a single-codepoint
;;;;     text object at least as wide as the view at the start of a row (it is
;;;;     pushed back and only marker rows are emitted until the height budget
;;;;     runs out); k-wrap reproduces exactly that, which is why fuel -- not
;;;;     list length -- is the termination measure (theorem
;;;;     `k-wrap-row-blocked' states the stuck case precisely).
;;;;   * CHAR GRANULARITY / EXACT WIDTHS.  Production explode-object re-measures
;;;;     each half via object-width; on ncurses that is string-width from
;;;;     column 0, which equals the sum of the per-char widths recorded here for
;;;;     every object the display pipeline actually builds (runs are char-type
;;;;     homogeneous; TAB is the only column-dependent width and raw tabs are
;;;;     expanded/replaced before objects are built, while a tab run's per-char
;;;;     deltas from column 0 are all tab-size anyway).  Production
;;;;     clip-objects-to-display-range approximates per-char width as
;;;;     total/len; that approximation is exact precisely for uniform-width
;;;;     runs, and the SDL2 surface-metrics case it exists for is OUT OF SCOPE
;;;;     (monospace non-goal).  k-clip-chars instead walks the EXACT per-char
;;;;     width list -- for uniform-width runs (the ncurses reality) the two
;;;;     agree; for mixed-width runs the kernel is the char-exact semantics.
;;;;     Documented deviation; see verified/README.md (VK-11).
;;;;
;;;; PROOF OBLIGATIONS (SPEC-VK VK-11).
;;;;   1. Content preservation -- `k-wrap-row-preserves-contents' /
;;;;      `k-wrap-preserves-contents' (+ the -wcontents width-list versions):
;;;;      appending the rows' contents and the leftover's contents reproduces
;;;;      the input contents exactly: nothing dropped, duplicated or reordered
;;;;      (opaque objects appear in the content stream as themselves).
;;;;   2. Width bound -- `k-wrap-row-width-bound' / `k-wrap-rows-fit':
;;;;      every emitted row's total width <= (view-width - 1) + the width of
;;;;      the row's OPAQUE objects; with all-zero opaque widths (ncurses):
;;;;      strictly < view-width (`k-wrap-rows-all-lt').  The precise exception
;;;;      statement: production never over-fills a row with TEXT (an oversized
;;;;      single codepoint is never placed at all -- `k-wrap-row-blocked'); only
;;;;      unbreakable non-text objects can push a row past the view width.
;;;;   3. Termination/totality -- admission itself: k-wrap-row terminates by
;;;;      the explode-tree node-count measure `k-objs-msr' (halving strictly
;;;;      decreases it), k-wrap by fuel; both are total functions.
;;;;   4. Clip correctness -- `k-clip-width-bound' (clipped output fits the
;;;;      display range), `k-clip-keeps-fully-visible' (a fully-visible object
;;;;      survives clipping verbatim), `k-scroll-adjust-contains-cursor' (the
;;;;      auto-scroll postcondition: the adjusted range contains the cursor),
;;;;      and their composition `k-clip-contains-cursor-object'.
;;;;
;;;; EXEC PATH (functions the adapter/tests call): `k-text', `k-opaque',
;;;;   `k-wrap-row', `k-wrap', `k-clip', `k-scroll-adjust' and their callees.
;;;;   These use only CL homonyms + the shim whitelist (natp, len, true-listp);
;;;;   no new whitelist entry is needed.  The proof-only helper `k-obj-pos'
;;;;   uses zp (as width.lisp's k-take does): it loads in-image but is never
;;;;   called there -- calling it would fail loudly, which is the shim's
;;;;   intended enforcement.
;;;;
;;;; STACK SAFETY (OPT-1 bug fix; bench/README.md ledger).  Redisplay reaches
;;;;   this book with per-char lists as long as the logical line, so any
;;;;   non-tail recursion of that depth overflows the default SBCL control
;;;;   stack (production crash: a single line >= ~24k chars through
;;;;   redraw-display, ~50k through redraw-buffer).  The three recursions whose
;;;;   depth equals the line length on the render path -- `k-sum' (every
;;;;   object-width measurement), `k-firstn' (explode halving) and
;;;;   `k-clip-chars' (per-char clip scan) -- are therefore defined with
;;;;   ACL2's `mbe': the :logic body is the original recursion (every theorem
;;;;   and the definitional axiom are unchanged), the :exec body a
;;;;   tail-recursive accumulator twin proved EQUAL at guard verification and
;;;;   run by certified execution (and, via the shim's mbe expansion, by the
;;;;   image -- SBCL's compiling load eliminates the tail calls).  The other
;;;;   recursions on the path are not line-length-deep: `k-wrap-row's explode
;;;;   retry and `k-clip's skip-before-range branch are genuine tail calls,
;;;;   their cons-building branches recurse once per PLACED/KEPT object (bounded
;;;;   by the view width per row / range), and `k-wrap' recurses once per fuel
;;;;   row.  Pinned at 300k chars by tests/pbt/long-line-render.lisp.

(in-package "ACL2")

;;; ===========================================================================
;;; Floor facts for the halving split point (arithmetic-5 kept local).
;;; This encapsulate must precede the top-with-meta include: with both
;;; arithmetic libraries active at once the rewriter loops on these goals.
;;; ===========================================================================

(encapsulate ()
  (local (include-book "arithmetic-5/top" :dir :system))
  (defthm floor-half-lower
    (implies (and (natp l) (<= 2 l))
             (<= 1 (floor l 2)))
    :rule-classes :linear)
  (defthm floor-half-upper
    (implies (and (natp l) (<= 1 l))
             (< (floor l 2) l))
    :rule-classes :linear)
  (defthm natp-of-floor-half
    (implies (natp l)
             (natp (floor l 2)))
    :rule-classes :type-prescription))

;; Stable arithmetic base (as in width.lisp).
(local (include-book "arithmetic/top-with-meta" :dir :system))

;; Keep floor opaque so the linear rules above drive the measure proof instead
;; of the base rewriter unfolding floor.
(in-theory (disable floor))

;;; ===========================================================================
;;; Display objects
;;; ===========================================================================

;; Nat coercion (nfix is ACL2-only, not CL-loadable; this is its exec twin).
;; Guard-verified (trivially) so the guard-verified mbe functions below may
;; call it.
(defun k-nat (x)
  (declare (xargs :guard t))
  (if (natp x) x 0))

(defun k-text (codes widths tag)
  (list :text codes widths tag))

(defun k-opaque (width tag)
  (list :opaque width tag))

(defun k-text-p (obj)
  (and (consp obj) (equal (car obj) :text)))

(defun k-obj-codes (obj)
  (car (cdr obj)))

(defun k-obj-widths (obj)
  (car (cdr (cdr obj))))

(defun k-text-tag (obj)
  (car (cdr (cdr (cdr obj)))))

(defun k-opaque-width (obj)
  (car (cdr obj)))

(defun k-opaque-tag (obj)
  (car (cdr (cdr obj))))

;; Tail-recursive accumulator twin of k-sum (the :exec body below).  Redisplay
;; measures every text object through k-sum over its FULL per-char width list,
;; so a non-tail fold's stack depth equals the line length (the OPT-1 crash;
;; see the STACK SAFETY header note).
(defun k-sum-acc (l acc)
  (declare (xargs :guard (natp acc)))
  (if (atom l)
      acc
      (k-sum-acc (cdr l) (+ (k-nat (car l)) acc))))

;; Sum of a width list (junk entries count 0, so widths are naturals with no
;; hypotheses anywhere downstream).  :logic is the original recursion (the
;; definitional axiom every theorem below is proved about); :exec is the
;; accumulator twin, proved equal at guard verification (below) and run by
;; certified execution.
(defun k-sum (l)
  (declare (xargs :guard t :verify-guards nil))
  (mbe :logic (if (atom l)
                  0
                  (+ (k-nat (car l)) (k-sum (cdr l))))
       :exec (k-sum-acc l 0)))

(defthm k-sum-acc-removal
  (implies (natp acc)
           (equal (k-sum-acc l acc)
                  (+ acc (k-sum l))))
  :hints (("Goal" :induct (k-sum-acc l acc))))

(verify-guards k-sum)

;; Production object-width: for a text object, string-width of its string --
;; here by construction the sum of the per-char widths; for an opaque object,
;; its recorded width.
(defun k-obj-width (obj)
  (if (k-text-p obj)
      (k-sum (k-obj-widths obj))
      (k-nat (k-opaque-width obj))))

(defthm natp-k-sum
  (natp (k-sum l))
  :rule-classes :type-prescription)

(defthm natp-k-obj-width
  (natp (k-obj-width obj))
  :rule-classes :type-prescription)

;;; ===========================================================================
;;; Halving (production explode-object)
;;; ===========================================================================

;; Tail-recursive accumulator twin of k-firstn (the :exec body below).
;; k-explode calls k-firstn with half the object's codes/widths, so a non-tail
;; recursion is line-length-deep on the wrap path (OPT-1; STACK SAFETY note).
(defun k-firstn-acc (n l acc)
  (declare (xargs :guard (true-listp acc)))
  (if (or (not (natp n)) (equal n 0) (atom l))
      (revappend acc nil)
      (k-firstn-acc (- n 1) (cdr l) (cons (car l) acc))))

;; First N elements (CL has no `take'; nil-terminated by construction).
(defun k-firstn (n l)
  (declare (xargs :guard t :verify-guards nil))
  (mbe :logic (if (or (not (natp n)) (equal n 0) (atom l))
                  nil
                  (cons (car l) (k-firstn (- n 1) (cdr l))))
       :exec (k-firstn-acc n l nil)))

(defthm k-firstn-acc-removal
  (implies (true-listp acc)
           (equal (k-firstn-acc n l acc)
                  (revappend acc (k-firstn n l))))
  :hints (("Goal" :induct (k-firstn-acc n l acc))))

(verify-guards k-firstn)

;; explode-object: split the run at (floor len 2); both halves inherit the tag
;; (production: same attribute, char-type of the first char -- recorded in the
;; tag by the adapter).  Only called on text objects with >= 2 codepoints, so
;; both halves are nonempty (production's :unless emptyp filter never fires).
(defun k-explode (obj)
  (let ((n (floor (len (k-obj-codes obj)) 2)))
    (list (k-text (k-firstn n (k-obj-codes obj))
                  (k-firstn n (k-obj-widths obj))
                  (k-text-tag obj))
          (k-text (nthcdr n (k-obj-codes obj))
                  (nthcdr n (k-obj-widths obj))
                  (k-text-tag obj)))))

;;; ===========================================================================
;;; Termination measure: explode-tree node count
;;; ===========================================================================
;;; f(text of len L>=1) = 2L-1 (nodes of its binary split tree), f(anything
;;; else) = 1.  Halving replaces 2L-1 by (2n-1)+(2(L-n)-1) = 2L-2: strictly
;;; smaller; consuming an object removes >= 1.

(defun k-obj-msr (obj)
  (if (and (k-text-p obj)
           (< 1 (len (k-obj-codes obj))))
      (- (* 2 (len (k-obj-codes obj))) 1)
      1))

(defun k-objs-msr (objs)
  (if (atom objs)
      0
      (+ (k-obj-msr (car objs)) (k-objs-msr (cdr objs)))))

(defthm natp-k-objs-msr
  (natp (k-objs-msr objs))
  :rule-classes :type-prescription)

(defthm k-obj-msr-positive
  (< 0 (k-obj-msr obj))
  :rule-classes :linear)

(defthm k-objs-msr-of-append
  (equal (k-objs-msr (append a b))
         (+ (k-objs-msr a) (k-objs-msr b))))

(defthm len-of-k-firstn
  (implies (natp n)
           (equal (len (k-firstn n l))
                  (min n (len l)))))

(local (defthm nthcdr-of-nil
         (equal (nthcdr n nil) nil)))

(defthm len-of-nthcdr
  (implies (natp n)
           (equal (len (nthcdr n l))
                  (if (< (len l) n) 0 (- (len l) n)))))

(defthm k-objs-msr-of-k-explode
  (implies (and (k-text-p obj)
                (< 1 (len (k-obj-codes obj))))
           (< (k-objs-msr (k-explode obj)) (k-obj-msr obj)))
  :rule-classes :linear)

;;; ===========================================================================
;;; k-wrap-row -- one physical row (production separate-objects-by-width)
;;; ===========================================================================
;;; Returns (mv row rest): ROW is the emitted physical row (marker abstracted;
;;; production appends the wrap-line-character letter object exactly when REST
;;; is non-nil), REST the objects deferred to the next row.  TOTAL is the
;;; running row width (production total-width; callers start at 0).

(defun k-wrap-row (objects view-width total)
  (declare (xargs :measure (k-objs-msr objects)))
  (if (atom objects)
      (mv nil nil)
      (let ((obj (car objects)))
        (if (and (k-text-p obj)
                 (<= view-width (+ total (k-obj-width obj))))
            (if (< 1 (len (k-obj-codes obj)))
                ;; overflow, still splittable: halve and re-try
                (k-wrap-row (append (k-explode obj) (cdr objects))
                            view-width total)
                ;; overflow, unbreakable single codepoint: emit the row, push
                ;; the object back (production returns (values row objects))
                (mv nil objects))
            ;; fits (or is non-text, placed unconditionally): accumulate
            (mv-let (row rest)
                    (k-wrap-row (cdr objects) view-width
                                (+ total (k-obj-width obj)))
              (mv (cons obj row) rest))))))

;;; ===========================================================================
;;; k-wrap -- full wrap (production redraw-logical-line-when-line-wrapping loop)
;;; ===========================================================================
;;; FUEL is the row budget: production renders rows only while y < window
;;; height, and on ncurses every row has height 1, so fuel is exactly that
;;; cutoff.  Returns (mv rows rest); REST is what did not fit the budget
;;; (off-screen in production, dropped by the height check).

(defun k-wrap (objects view-width fuel)
  (declare (xargs :measure (nfix fuel)))
  (if (or (atom objects)
          (not (natp fuel))
          (equal fuel 0))
      (mv nil objects)
      (mv-let (row rest)
              (k-wrap-row objects view-width 0)
        (mv-let (rows final-rest)
                (k-wrap rest view-width (- fuel 1))
          (mv (cons row rows) final-rest)))))

;;; ===========================================================================
;;; Contents (obligation 1 vocabulary)
;;; ===========================================================================
;;; The content stream of an object list: a text object contributes its
;;; codepoints, an opaque object contributes itself (so opaque objects too are
;;; provably neither dropped, duplicated nor reordered).

(defun k-obj-contents (obj)
  (if (k-text-p obj)
      (k-obj-codes obj)
      (list obj)))

(defun k-objs-contents (objs)
  (if (atom objs)
      nil
      (append (k-obj-contents (car objs))
              (k-objs-contents (cdr objs)))))

(defun k-rows-contents (rows)
  (if (atom rows)
      nil
      (append (k-objs-contents (car rows))
              (k-rows-contents (cdr rows)))))

;; Width-list stream (the aligned per-char widths are preserved too).
(defun k-obj-wcontents (obj)
  (if (k-text-p obj)
      (k-obj-widths obj)
      nil))

(defun k-objs-wcontents (objs)
  (if (atom objs)
      nil
      (append (k-obj-wcontents (car objs))
              (k-objs-wcontents (cdr objs)))))

(defun k-rows-wcontents (rows)
  (if (atom rows)
      nil
      (append (k-objs-wcontents (car rows))
              (k-rows-wcontents (cdr rows)))))

;; Well-formedness needed by the content proofs: code/width lists are proper
;; lists (splitting at n and re-appending is then the identity).
(defun k-wf-obj (obj)
  (if (k-text-p obj)
      (and (true-listp (k-obj-codes obj))
           (true-listp (k-obj-widths obj)))
      t))

(defun k-wf-objects (objs)
  (if (atom objs)
      t
      (and (k-wf-obj (car objs))
           (k-wf-objects (cdr objs)))))

;;; ---- list lemmas ----------------------------------------------------------

(defthm append-associativity
  (equal (append (append a b) c)
         (append a (append b c))))

(defthm append-k-firstn-nthcdr
  (implies (true-listp l)
           (equal (append (k-firstn n l) (nthcdr n l))
                  l)))

;; Right-extended variant so the rewrite fires inside an association chain
;; (contents proofs produce (firstn ++ (nthcdr ++ x)) shapes).
(defthm append-k-firstn-nthcdr-assoc
  (implies (true-listp l)
           (equal (append (k-firstn n l) (append (nthcdr n l) x))
                  (append l x))))

(defthm true-listp-k-firstn
  (true-listp (k-firstn n l))
  :rule-classes :type-prescription)

(defthm true-listp-nthcdr
  (implies (true-listp l)
           (true-listp (nthcdr n l))))

(defthm k-objs-contents-of-append
  (equal (k-objs-contents (append a b))
         (append (k-objs-contents a) (k-objs-contents b))))

(defthm k-objs-wcontents-of-append
  (equal (k-objs-wcontents (append a b))
         (append (k-objs-wcontents a) (k-objs-wcontents b))))

(defthm k-wf-objects-of-append
  (equal (k-wf-objects (append a b))
         (and (k-wf-objects a) (k-wf-objects b))))

(defthm k-objs-contents-of-k-explode
  (implies (and (k-text-p obj) (k-wf-obj obj))
           (equal (k-objs-contents (k-explode obj))
                  (k-obj-codes obj))))

(defthm k-objs-wcontents-of-k-explode
  (implies (and (k-text-p obj) (k-wf-obj obj))
           (equal (k-objs-wcontents (k-explode obj))
                  (k-obj-widths obj))))

(defthm k-wf-objects-of-k-explode
  (implies (and (k-text-p obj) (k-wf-obj obj))
           (k-wf-objects (k-explode obj))))

;;; ===========================================================================
;;; Obligation 1: content preservation
;;; ===========================================================================

(defthm k-wrap-row-wf
  (implies (k-wf-objects objects)
           (and (k-wf-objects (car (k-wrap-row objects view-width total)))
                (k-wf-objects (mv-nth 1 (k-wrap-row objects view-width total)))))
  :hints (("Goal" :induct (k-wrap-row objects view-width total))))

(defthm k-wrap-row-preserves-contents
  (implies (k-wf-objects objects)
           (equal (append
                   (k-objs-contents (car (k-wrap-row objects view-width total)))
                   (k-objs-contents (mv-nth 1 (k-wrap-row objects view-width total))))
                  (k-objs-contents objects)))
  :hints (("Goal" :induct (k-wrap-row objects view-width total))))

(defthm k-wrap-row-preserves-wcontents
  (implies (k-wf-objects objects)
           (equal (append
                   (k-objs-wcontents (car (k-wrap-row objects view-width total)))
                   (k-objs-wcontents (mv-nth 1 (k-wrap-row objects view-width total))))
                  (k-objs-wcontents objects)))
  :hints (("Goal" :induct (k-wrap-row objects view-width total))))

(defthm k-wrap-preserves-contents
  (implies (k-wf-objects objects)
           (equal (append
                   (k-rows-contents (car (k-wrap objects view-width fuel)))
                   (k-objs-contents (mv-nth 1 (k-wrap objects view-width fuel))))
                  (k-objs-contents objects)))
  :hints (("Goal" :induct (k-wrap objects view-width fuel))))

(defthm k-wrap-preserves-wcontents
  (implies (k-wf-objects objects)
           (equal (append
                   (k-rows-wcontents (car (k-wrap objects view-width fuel)))
                   (k-objs-wcontents (mv-nth 1 (k-wrap objects view-width fuel))))
                  (k-objs-wcontents objects)))
  :hints (("Goal" :induct (k-wrap objects view-width fuel))))

;;; ===========================================================================
;;; Obligation 2: width bound
;;; ===========================================================================

(defun k-row-width (objs)
  (if (atom objs)
      0
      (+ (k-obj-width (car objs)) (k-row-width (cdr objs)))))

;; Width contributed by the row's opaque (unbreakable non-text) objects.
(defun k-row-opq-width (objs)
  (if (atom objs)
      0
      (+ (if (k-text-p (car objs)) 0 (k-obj-width (car objs)))
         (k-row-opq-width (cdr objs)))))

(defthm natp-k-row-width
  (natp (k-row-width objs))
  :rule-classes :type-prescription)

(defthm natp-k-row-opq-width
  (natp (k-row-opq-width objs))
  :rule-classes :type-prescription)

;; The invariant behind separate-objects-by-width: a text object is placed only
;; while total + width < view-width, so text can fill a row to at most
;; view-width - 1 columns; ONLY opaque objects (placed unconditionally, exactly
;; as production places non-text objects) can push a row further.  This is the
;; precise form of the "single unbreakable unit" exception: on the text path
;; there is NO exception (an oversized single codepoint is never placed at all;
;; see k-wrap-row-blocked), and any excess over view-width - 1 is attributable
;; to the row's opaque objects, column for column.
(defthm k-wrap-row-width-bound
  (implies (and (natp total)
                (integerp view-width))
           (<= (k-row-width (car (k-wrap-row objects view-width total)))
               (+ (k-row-opq-width (car (k-wrap-row objects view-width total)))
                  (max 0 (- view-width (+ total 1))))))
  :hints (("Goal" :induct (k-wrap-row objects view-width total)))
  :rule-classes :linear)

;; All opaque objects have width 0 (the ncurses reality: void, eol-cursor,
;; extend-to-eol and image objects all measure 0).
(defun k-zero-opq-p (objs)
  (if (atom objs)
      t
      (and (or (k-text-p (car objs))
               (equal (k-obj-width (car objs)) 0))
           (k-zero-opq-p (cdr objs)))))

(defthm k-zero-opq-p-of-append
  (equal (k-zero-opq-p (append a b))
         (and (k-zero-opq-p a) (k-zero-opq-p b))))

(defthm k-zero-opq-p-of-k-explode
  (k-zero-opq-p (k-explode obj)))

(defthm k-row-opq-width-when-zero-opq
  (implies (k-zero-opq-p objs)
           (equal (k-row-opq-width objs) 0)))

(defthm k-wrap-row-zero-opq
  (implies (k-zero-opq-p objects)
           (and (k-zero-opq-p (car (k-wrap-row objects view-width total)))
                (k-zero-opq-p (mv-nth 1 (k-wrap-row objects view-width total)))))
  :hints (("Goal" :induct (k-wrap-row objects view-width total))))

;; ncurses corollary: with zero-width opaques every row is strictly narrower
;; than the view.
(defthm k-wrap-row-width-strict
  (implies (and (natp total)
                (posp view-width)
                (k-zero-opq-p objects))
           (< (k-row-width (car (k-wrap-row objects view-width total)))
              view-width))
  :hints (("Goal" :use ((:instance k-wrap-row-width-bound))
           :in-theory (disable k-wrap-row-width-bound)))
  :rule-classes :linear)

;; Lift to every row of k-wrap.
(defun k-rows-fit-p (rows view-width)
  (if (atom rows)
      t
      (and (<= (k-row-width (car rows))
               (+ (k-row-opq-width (car rows))
                  (max 0 (- view-width 1))))
           (k-rows-fit-p (cdr rows) view-width))))

(defthm k-wrap-rows-fit
  (implies (integerp view-width)
           (k-rows-fit-p (car (k-wrap objects view-width fuel)) view-width))
  :hints (("Goal" :induct (k-wrap objects view-width fuel))))

(defun k-rows-lt-p (rows view-width)
  (if (atom rows)
      t
      (and (< (k-row-width (car rows)) view-width)
           (k-rows-lt-p (cdr rows) view-width))))

(defthm k-wrap-rows-all-lt
  (implies (and (posp view-width)
                (k-zero-opq-p objects))
           (k-rows-lt-p (car (k-wrap objects view-width fuel)) view-width))
  :hints (("Goal" :induct (k-wrap objects view-width fuel))))

;;; ===========================================================================
;;; The stuck case, stated precisely (part of obligation 2's exception)
;;; ===========================================================================
;;; k-wrap-row emits an empty row while deferring work ONLY when the row starts
;;; with an unbreakable (<= 1 codepoint) text object at least as wide as the
;;; remaining view: production pushes it back, emits the wrap marker alone, and
;;; retries forever (bounded by the window height = k-wrap's fuel).  Nothing is
;;; consumed (that is content preservation with an empty row); this theorem
;;; characterizes the blocking head.

(defthm k-wrap-row-blocked
  (implies (and (not (consp (car (k-wrap-row objects view-width total))))
                (consp (mv-nth 1 (k-wrap-row objects view-width total))))
           (and (k-text-p (car (mv-nth 1 (k-wrap-row objects view-width total))))
                (<= (len (k-obj-codes
                          (car (mv-nth 1 (k-wrap-row objects view-width total)))))
                    1)
                (<= view-width
                    (+ total
                       (k-obj-width
                        (car (mv-nth 1 (k-wrap-row objects view-width total))))))))
  :hints (("Goal" :induct (k-wrap-row objects view-width total)))
  :rule-classes nil)

;;; ===========================================================================
;;; k-clip-chars / k-clip (production clip-objects-to-display-range)
;;; ===========================================================================
;;; Per-char selection of the codepoints of a straddling text object that are
;;; FULLY inside [start-x, end-x), walking the EXACT per-char widths (see the
;;; header on the total/len deviation).  Mirrors production's scan: stop as
;;; soon as the column reaches end-x; a char is kept iff start-x <= char-x and
;;; char-x + width <= end-x (production's start-idx/end-idx interval is exactly
;;; this set: the kept chars are contiguous because the column is monotone).

;; Tail-recursive accumulator twin of k-clip-chars (the :exec body below).
;; The clip scan walks the straddling object's chars up to end-x, so a
;; non-tail recursion is line-length-deep on the horizontal-scroll path
;; (OPT-1; STACK SAFETY note).  Same per-char keep condition, kept chars
;; accumulated in reverse and restored by revappend.
(defun k-clip-chars-acc (codes widths x start-x end-x acc-codes acc-widths)
  (declare (xargs :guard (and (natp x) (integerp start-x) (integerp end-x)
                              (true-listp widths)
                              (true-listp acc-codes)
                              (true-listp acc-widths))))
  (if (or (atom codes)
          (<= end-x x))
      (mv (revappend acc-codes nil) (revappend acc-widths nil))
      (let ((cw (k-nat (car widths))))
        (if (and (<= start-x x)
                 (<= (+ x cw) end-x))
            (k-clip-chars-acc (cdr codes) (cdr widths) (+ x cw) start-x end-x
                              (cons (car codes) acc-codes)
                              (cons (car widths) acc-widths))
            (k-clip-chars-acc (cdr codes) (cdr widths) (+ x cw) start-x end-x
                              acc-codes acc-widths)))))

(defun k-clip-chars (codes widths x start-x end-x)
  (declare (xargs :guard (and (natp x) (integerp start-x) (integerp end-x)
                              (true-listp widths))
                  :verify-guards nil))
  (mbe :logic
       (if (atom codes)
           (mv nil nil)
           (if (<= end-x x)             ; production: (>= char-x end-x) -> return
               (mv nil nil)
               (let ((cw (k-nat (car widths))))
                 (mv-let (sel-codes sel-widths)
                         (k-clip-chars (cdr codes) (cdr widths)
                                       (+ x cw) start-x end-x)
                   (if (and (<= start-x x)
                            (<= (+ x cw) end-x))
                       (mv (cons (car codes) sel-codes)
                           (cons (car widths) sel-widths))
                       (mv sel-codes sel-widths))))))
       :exec (k-clip-chars-acc codes widths x start-x end-x nil nil)))

;; A k-clip-chars value IS the two-element list of its components (every
;; return site is an (mv a b)); lets the removal lemma rebuild the whole
;; value from the car/mv-nth components.
(defthm k-clip-chars-shape
  (equal (list (car (k-clip-chars codes widths x start-x end-x))
               (mv-nth 1 (k-clip-chars codes widths x start-x end-x)))
         (k-clip-chars codes widths x start-x end-x))
  :hints (("Goal" :induct (k-clip-chars codes widths x start-x end-x))))

(defthm k-clip-chars-acc-removal
  (implies (and (true-listp acc-codes)
                (true-listp acc-widths))
           (equal (k-clip-chars-acc codes widths x start-x end-x
                                    acc-codes acc-widths)
                  (mv (revappend acc-codes
                                 (car (k-clip-chars codes widths x start-x end-x)))
                      (revappend acc-widths
                                 (mv-nth 1 (k-clip-chars codes widths x
                                                         start-x end-x))))))
  :hints (("Goal" :induct (k-clip-chars-acc codes widths x start-x end-x
                                            acc-codes acc-widths))))

(verify-guards k-clip-chars)

;; clip-objects-to-display-range: X is the running column (callers start at 0).
;;   - object entirely left of the range: skipped;
;;   - column already past the range: everything after is dropped (production's
;;;    early return);
;;   - object fully inside: passed through UNCHANGED (same object);
;;   - straddling text object: replaced by the sub-run of fully-visible chars
;;     (production: make-object-with-type on the substring, same attribute and
;;     type -- the tag carries those), omitted when no char is fully visible;
;;   - straddling non-text object: passed through whole (unreachable on
;;     ncurses where opaque widths are 0).

(defun k-clip (objects x start-x end-x)
  (if (atom objects)
      nil
      (let* ((obj (car objects))
             (w (k-obj-width obj))
             (obj-end (+ x w)))
        (cond ((<= obj-end start-x)
               (k-clip (cdr objects) obj-end start-x end-x))
              ((<= end-x x)
               nil)
              ((and (<= start-x x) (<= obj-end end-x))
               (cons obj (k-clip (cdr objects) obj-end start-x end-x)))
              ((k-text-p obj)
               (mv-let (sel-codes sel-widths)
                       (k-clip-chars (k-obj-codes obj) (k-obj-widths obj)
                                     x start-x end-x)
                 (if (consp sel-codes)
                     (cons (k-text sel-codes sel-widths (k-text-tag obj))
                           (k-clip (cdr objects) obj-end start-x end-x))
                     (k-clip (cdr objects) obj-end start-x end-x))))
              (t
               (cons obj (k-clip (cdr objects) obj-end start-x end-x)))))))

;;; ===========================================================================
;;; Obligation 4a: the clipped output fits the display range
;;; ===========================================================================

;; The selected sub-run occupies a sub-interval of [max(start-x, x), min(end-x,
;; x + total width)): its width is bounded by that interval's length.
(defthm k-clip-chars-width-bound
  (implies (and (natp x) (integerp start-x) (integerp end-x))
           (<= (k-sum (mv-nth 1 (k-clip-chars codes widths x start-x end-x)))
               (max 0 (- (min end-x (+ x (k-sum widths)))
                         (max start-x x)))))
  :hints (("Goal" :induct (k-clip-chars codes widths x start-x end-x)))
  :rule-classes :linear)

(defthm k-obj-width-of-k-text-clip-chars
  (equal (k-obj-width (k-text (car (k-clip-chars codes widths x s e))
                              (mv-nth 1 (k-clip-chars codes widths x s e))
                              tag))
         (k-sum (mv-nth 1 (k-clip-chars codes widths x s e)))))

(defthm k-clip-width-bound
  (implies (and (natp x) (integerp start-x) (integerp end-x)
                (k-zero-opq-p objects))
           (<= (k-row-width (k-clip objects x start-x end-x))
               (max 0 (- end-x (max start-x x)))))
  :hints (("Goal" :induct (k-clip objects x start-x end-x)))
  :rule-classes :linear)

;;; ===========================================================================
;;; Obligation 4b: fully-visible objects survive clipping verbatim
;;; ===========================================================================

;; Column at which the I-th object starts (proof-only vocabulary).
(defun k-obj-pos (objs x i)
  (if (or (zp i) (atom objs))
      x
      (k-obj-pos (cdr objs) (+ x (k-obj-width (car objs))) (- i 1))))

(defthm k-obj-pos-lower-bound
  (implies (natp x)
           (<= x (k-obj-pos objs x i)))
  :rule-classes :linear)

(defthm natp-k-obj-pos
  (implies (natp x)
           (natp (k-obj-pos objs x i)))
  :rule-classes :type-prescription)

;; An object lying fully inside [start-x, end-x) -- with the strict-side
;; conditions production's cond order imposes (a zero-width object exactly at
;; either boundary is classified before/after, not within) -- appears in the
;; clipped output unchanged.
(defthm k-clip-keeps-fully-visible
  (implies (and (natp x) (integerp start-x) (integerp end-x)
                (natp i) (< i (len objects))
                (<= start-x (k-obj-pos objects x i))
                (< (k-obj-pos objects x i) end-x)
                (<= (+ (k-obj-pos objects x i)
                       (k-obj-width (nth i objects)))
                    end-x)
                (< start-x (+ (k-obj-pos objects x i)
                              (k-obj-width (nth i objects)))))
           (member-equal (nth i objects)
                         (k-clip objects x start-x end-x)))
  :hints (("Goal" :induct (k-obj-pos objects x i))))

;;; ===========================================================================
;;; Obligation 4c: auto-scroll postcondition
;;; ===========================================================================
;;; Transcribes redraw-logical-line-when-horizontal-scroll's adjustment of
;;; horizontal-scroll-start: scroll left to the cursor when it is left of the
;;; window; scroll right so the cursor's right edge is flush when it is right
;;; of it; otherwise leave the scroll alone.  WIDTH is view-width minus the
;;; left-side (line number) width.

(defun k-scroll-adjust (start width cursor-x cursor-w)
  (cond ((< cursor-x start)
         cursor-x)
        ((< (+ start width) (+ cursor-x cursor-w))
         (+ (- cursor-x width) cursor-w))
        (t start)))

;; The adjusted range [start', start' + width) contains the cursor's cells
;; [cursor-x, cursor-x + cursor-w) whenever the cursor is no wider than the
;; window -- the production guarantee.
(defthm k-scroll-adjust-contains-cursor
  (implies (and (natp start) (natp width) (natp cursor-x) (natp cursor-w)
                (<= cursor-w width))
           (and (<= (k-scroll-adjust start width cursor-x cursor-w) cursor-x)
                (<= (+ cursor-x cursor-w)
                    (+ (k-scroll-adjust start width cursor-x cursor-w) width))))
  :rule-classes nil)

(defthm natp-k-scroll-adjust
  (implies (and (natp start) (natp width) (natp cursor-x) (natp cursor-w)
                (<= cursor-w width))
           (natp (k-scroll-adjust start width cursor-x cursor-w)))
  :rule-classes :type-prescription)

;;; Composition: after the auto-scroll adjustment, clipping to the adjusted
;;; window keeps the cursor object itself (production clips to view-width >=
;;; width, so the cursor -- placed within [start', start' + width) -- is fully
;;; visible).  Hypotheses: the cursor object is the I-th object, its width is
;;; positive (a zero-width cursor object flush with the right edge is dropped
;;; by production's boundary classification) and at most WIDTH.

(defthm k-clip-contains-cursor-object
  (implies (and (natp x) (natp start) (natp width) (natp view-width)
                (<= width view-width)
                (natp i) (< i (len objects))
                (equal cursor-x (k-obj-pos objects x i))
                (equal cursor-w (k-obj-width (nth i objects)))
                (posp cursor-w)
                (<= cursor-w width))
           (member-equal
            (nth i objects)
            (k-clip objects x
                    (k-scroll-adjust start width cursor-x cursor-w)
                    (+ (k-scroll-adjust start width cursor-x cursor-w)
                       view-width))))
  :hints (("Goal"
           :use ((:instance k-scroll-adjust-contains-cursor
                            (cursor-x (k-obj-pos objects x i))
                            (cursor-w (k-obj-width (nth i objects))))
                 (:instance k-clip-keeps-fully-visible
                            (start-x (k-scroll-adjust
                                      start width
                                      (k-obj-pos objects x i)
                                      (k-obj-width (nth i objects))))
                            (end-x (+ (k-scroll-adjust
                                       start width
                                       (k-obj-pos objects x i)
                                       (k-obj-width (nth i objects)))
                                      view-width))))
           :in-theory (disable k-clip-keeps-fully-visible
                               k-scroll-adjust)))
  :rule-classes nil)
