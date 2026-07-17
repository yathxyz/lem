;;;; verified/width.lisp -- Character/string width algebra kernel (SPEC-VK VK-10).
;;;;
;;;; One source of truth (SPEC-VK Constraint 2): this same file is certified by
;;;; ACL2 (scripts/run-proofs.sh) AND loaded verbatim into the Lem SBCL image
;;;; through verified/shim.lisp, where production
;;;; src/common/character/string-width-utils.lisp is a thin shell over
;;;; `k-char-width' (the per-codepoint width function the redisplay-hot loops
;;;; call once per character, with char-code -- no per-call list allocation).
;;;;
;;;; REPRESENTATION.  Text is codepoints (naturals), never ACL2 strings/chars
;;;; (ACL2 chars are 8-bit).  `k-char-width' takes a codepoint, the CURRENT
;;;; column, the tab size, an ICON-P flag and the AMBIGUOUS width, and returns
;;;; the NEW column after placing that codepoint -- exactly production
;;;; `char-width' (which returns the updated `width', not a delta).
;;;;
;;;; PRODUCTION SEMANTICS MIRRORED (src/common/character/string-width-utils.lisp
;;;; char-width, verbatim branch order):
;;;;   1. TAB (9)       -> next tab stop: (* (floor col tab) tab) + tab.
;;;;   2. NEWLINE (10)  -> 0 (column resets).
;;;;   3. CONTROL       -> col + (length of the *char-replacement* string).  The
;;;;      replacement (caret form "^X" for 0-31/127, backslash form "\\N" for the
;;;;      private-use range #xE000..#xE0FF) is displayed literally; production
;;;;      recurses char-width over it, and since every replacement glyph is a
;;;;      narrow ASCII character (each +1) the recursion's result is exactly
;;;;      col + (len replacement).  `k-control-len' returns that length; the
;;;;      recursion->+length collapse is witnessed by `narrow-run-is-plus-len'.
;;;;   4. ZERO-WIDTH    -> col (combining marks Mn/Me + ZWJ; `zero-ranges').
;;;;   5. WIDE          -> col + 2 (▼ U+25BC, dynamically-registered icons via
;;;;      ICON-P, and East_Asian_Width W/F + Emoji_Presentation `wide-ranges').
;;;;   6. AMBIGUOUS     -> col + amb-width (East_Asian_Width A; `ambiguous-ranges';
;;;;      production reads the dynamic *ambiguous-character-width*, passed here as
;;;;      an explicit argument -- functional style, contract.yml functional_style).
;;;;   7. otherwise     -> col + 1 (narrow).
;;;;
;;;; ICONS.  Production `wide-char-p' also consults a RUNTIME hash table of
;;;; extension-registered icons (`icon-code-p'); that table is dynamic data the
;;;; kernel cannot hold, so ICON-P is threaded in as the exact wide-branch
;;;; boolean.  The proved width algebra below (`k-string-width'/`k-wide-index')
;;;; folds with ICON-P = NIL -- the static monospace model; an icon only ever
;;;; routes a codepoint to the wide (+2) branch, which preserves every property
;;;; proved here.  The shell passes the real `icon-code-p' per char and the
;;;; differential vectors (tests/pbt/width-vectors.lisp, captured from production
;;;; BEFORE the swap) pin the full string-width/wide-index to this kernel.
;;;;
;;;; EASTASIAN TABLES.  `k-wide-code-p'/`k-ambiguous-code-p'/`k-zero-code-p' are
;;;; the certified constant book verified/eastasian-data.lisp -- balanced
;;;; binary-search decision trees (nested-if literal comparisons) recognizing
;;;; EXACTLY the codepoints of production's *eastasian-full*/*eastasian-ambiguous*/
;;;; *zero-width* (same UCD parse; both emitted by scripts/gen-eastasian.lisp).
;;;; SBCL compiles them to O(log n) literal integer compares -- as fast as
;;;; production's fasl, not an O(n) list scan.
;;;;
;;;; EXEC PATH (functions the shell actually calls): `k-char-width',
;;;; `k-string-width', `k-wide-index' and their callees (`k-wide-code-p',
;;;; `k-ambiguous-code-p', `k-zero-code-p', `k-control-code-p', `k-control-len',
;;;; `k-num-digits').  These use only CL homonyms + the shim whitelist entry
;;;; `natp' (verified/shim.lisp); NO new whitelist entry is needed.  `k-take',
;;;; `no-nl-p', `narrow-code-p', `all-narrow-p', `narrow-run' are proof-only.

(in-package "ACL2")

(include-book "eastasian-data")

;; Arithmetic lemma library (proof-only: local, nothing exec-reachable or
;; exported from it).  top-with-meta is the stable base (as in codec.lisp); the
;; heavier arithmetic-5 is confined to the floor/mod ENCAPSULATE below, whose
;; rewriter can loop on plain natp goals when enabled book-wide.
(local (include-book "arithmetic/top-with-meta" :dir :system))

;; `(floor col tab)' of two naturals is a natural -- the one arithmetic fact
;; natp-k-char-width needs for the TAB branch.  Proved with arithmetic-5 kept
;; local to this encapsulate (its rewriter can loop on plain natp goals when
;; enabled book-wide); exported as a type-prescription rule.
(encapsulate ()
  (local (include-book "arithmetic-5/top" :dir :system))
  (defthm natp-of-floor-nats
    (implies (and (natp col) (natp tab))
             (natp (floor col tab)))
    :rule-classes :type-prescription))

;;; ===========================================================================
;;; East-Asian classification (eastasian-data.lisp binary-search predicates)
;;; ===========================================================================
;;; `k-wide-code-p'/`k-ambiguous-code-p'/`k-zero-code-p' are the generated
;;; balanced binary-search decision trees (nested-if literal comparisons, O(log
;;; n), compiled by SBCL as fast as production's fasl).  k-char-width calls them
;;; DIRECTLY (no wrapper layer -- string-width is redisplay-hot and every extra
;;; per-codepoint function call shows up on a 10k-char line).
;;;
;;; Keep the classification machinery OPAQUE to the prover: expanding the big
;;; nested-if predicates blows the rewrite stack, and none of the width theorems
;;; depend on WHICH codes are wide/zero/ambiguous -- only that each classification
;;; predicate is a boolean, which drives k-char-width's cond by cases.
;;; (Execution is unaffected; disabling is proof-time only.)
;;; Also keep FLOOR/MOD opaque so the encapsulated floor/mod linear/rewrite rules
;;; fire on the TAB branch instead of the base rewriter unfolding floor into
;;; nonnegative-integer-quotient.
(in-theory (disable k-wide-code-p k-ambiguous-code-p k-zero-code-p floor mod))

;;; ===========================================================================
;;; Control-character replacement width (*char-replacement*)
;;; ===========================================================================

;; Decimal-digit count of I in 0..255 (I = code - #xE000 for the "\\N" range).
(defun k-num-digits (i)
  (cond ((< i 10) 1)
        ((< i 100) 2)
        (t 3)))

;; A production *char-replacement* key: caret form for 0-31 and 127, backslash
;; form for the private-use range #xE000..#xE0FF.  (9 and 10 fall in 0-31 but
;; `k-char-width' intercepts them as TAB/NEWLINE before this is consulted, so
;; including them here is harmless and matches production's table, which keeps a
;; "^I" entry for 9 and no entry for 10.)
(defun k-control-code-p (code)
  (and (natp code)
       (or (<= code 31)
           (equal code 127)
           (and (<= #xe000 code) (<= code #xe0ff)))))

;; Length of the replacement string: "^X" = 2 for the caret forms; "\\" + the
;; decimal digits of (code - #xE000) for the backslash forms.
(defun k-control-len (code)
  (if (and (<= #xe000 code) (<= code #xe0ff))
      (+ 1 (k-num-digits (- code #xe000)))
      2))

;;; ===========================================================================
;;; k-char-width -- the per-codepoint width step (EXEC entry)
;;; ===========================================================================

(defun k-char-width (code col tab-size icon-p amb-width)
  (cond ((equal code 9)                                  ; TAB
         (+ (* (floor col tab-size) tab-size) tab-size))
        ((equal code 10) 0)                              ; NEWLINE
        ((k-control-code-p code)                         ; control -> ^X / \N
         (+ col (k-control-len code)))
        ((k-zero-code-p code) col)                       ; combining / ZWJ
        ((or (equal code 9660)                           ; ▼ U+25BC
             icon-p                                       ; registered icon
             (k-wide-code-p code))                        ; East_Asian W/F / emoji
         (+ col 2))
        ((k-ambiguous-code-p code) (+ col amb-width))    ; ambiguous
        (t (+ col 1))))                                  ; narrow

;;; ===========================================================================
;;; k-string-width / k-wide-index (EXEC entries)
;;; ===========================================================================

;; Left fold of k-char-width from COL over CODES (the proved algebra folds with
;; ICON-P = NIL -- see the header on icons).  Production `string-width' is this
;; loop with the real per-char icon-code-p and start = 0.
(defun k-string-width (codes col tab-size amb-width)
  (if (atom codes)
      col
      (k-string-width (cdr codes)
                      (k-char-width (car codes) col tab-size nil amb-width)
                      tab-size amb-width)))

;; Production `wide-index' convention (string-width-utils.lisp wide-index): scan
;; from COL, and at the FIRST codepoint whose new inclusive width EXCEEDS GOAL
;; return its 0-based offset; return NIL if GOAL is never exceeded (i.e. the
;; whole run fits in GOAL columns).  The shell adds the absolute :start offset.
(defun k-wide-index (codes goal col tab-size amb-width)
  (if (atom codes)
      nil
      (let ((w (k-char-width (car codes) col tab-size nil amb-width)))
        (if (< goal w)
            0
            (let ((r (k-wide-index (cdr codes) goal w tab-size amb-width)))
              (if r (+ 1 r) nil))))))

;;; ===========================================================================
;;; Proof-only helpers
;;; ===========================================================================

(defun k-take (n l)
  (if (or (zp n) (atom l))
      nil
      (cons (car l) (k-take (- n 1) (cdr l)))))

;; A codepoint list free of newlines (10): the redisplay reality -- physical
;; lines are split on newline before measuring, so widths are monotone.
(defun no-nl-p (codes)
  (if (atom codes)
      t
      (and (not (equal (car codes) 10))
           (no-nl-p (cdr codes)))))

;; A codepoint taking the narrow (+1) branch: not tab/newline/control/zero/
;; wide/ambiguous.  Every *char-replacement* glyph (caret/backslash/digits, all
;; in 32..95) is narrow -- this recognizer plus `narrow-run-is-plus-len' below
;; witness the control-recursion -> +length collapse noted in the header.
(defun narrow-code-p (code)
  (and (not (equal code 9))
       (not (equal code 10))
       (not (k-control-code-p code))
       (not (k-zero-code-p code))
       (not (equal code 9660))
       (not (k-wide-code-p code))
       (not (k-ambiguous-code-p code))))

(defun all-narrow-p (codes)
  (if (atom codes)
      t
      (and (narrow-code-p (car codes))
           (all-narrow-p (cdr codes)))))

;;; ===========================================================================
;;; Basic type facts
;;; ===========================================================================

(defthm natp-k-control-len
  (natp (k-control-len code))
  :rule-classes :type-prescription)

(defthm natp-k-char-width
  (implies (and (natp col) (natp amb-width) (natp tab-size))
           (natp (k-char-width code col tab-size icon-p amb-width)))
  :rule-classes :type-prescription)

(defthm natp-k-string-width
  (implies (and (natp col) (natp amb-width) (natp tab-size))
           (natp (k-string-width codes col tab-size amb-width)))
  :rule-classes :type-prescription)

;;; ===========================================================================
;;; Obligation 4: tab-stop law
;;;   after a tab, the column is the LEAST multiple of tab-size strictly greater
;;;   than the current column.
;;; ===========================================================================

;; k-char-width of TAB = (floor col tab)*tab + tab, the next tab stop.  Proved
;; with arithmetic-5 local to this encapsulate; the TAB branch is k-char-width's
;; FIRST cond clause, so opening it never touches the (disabled) range tables.
(encapsulate ()
  (local (include-book "arithmetic-5/top" :dir :system))

  ;; Strictly greater than the current column.
  (defthm tab-stop-strictly-greater
    (implies (and (natp col) (posp tab-size))
             (< col (k-char-width 9 col tab-size icon amb))))

  ;; A multiple of the tab size.
  (defthm tab-stop-is-a-multiple
    (implies (and (natp col) (posp tab-size))
             (equal (mod (k-char-width 9 col tab-size icon amb) tab-size)
                    0)))

  ;; LEAST such multiple: dropping one tab-size lands at or below the old
  ;; column, so nothing between (result - tab-size) and result is a tab stop.
  (defthm tab-stop-is-least
    (implies (and (natp col) (posp tab-size))
             (<= (- (k-char-width 9 col tab-size icon amb) tab-size)
                 col))))

;;; ===========================================================================
;;; Obligation 2: monotonicity
;;;   width of a prefix <= width of the whole (for newline-free input; a newline
;;;   resets the column to 0, which is production's behavior and why physical
;;;   lines are split on newline before measuring).
;;; ===========================================================================

;; Every non-newline codepoint step is non-decreasing on the column.  (Ranges
;; stay disabled, so the cond splits on opaque predicates; arithmetic-5 is local
;; for the TAB branch's floor bound.)
(encapsulate ()
  (local (include-book "arithmetic-5/top" :dir :system))
  (defthm k-char-width-lower-bound
    (implies (and (natp col) (natp amb-width) (posp tab-size)
                  (not (equal code 10)))
             (<= col (k-char-width code col tab-size icon-p amb-width)))
    :rule-classes :linear))

;; Keep k-char-width OPAQUE here so the k-char-width-lower-bound linear rule
;; fires on each fold step instead of the tab branch re-opening into floor.
(defthm k-string-width-monotone-col
  (implies (and (natp col) (natp amb-width) (posp tab-size)
                (no-nl-p codes))
           (<= col (k-string-width codes col tab-size amb-width)))
  :hints (("Goal" :in-theory (disable k-char-width)
           :induct (k-string-width codes col tab-size amb-width))))

(defthm no-nl-p-of-append
  (equal (no-nl-p (append a b))
         (and (no-nl-p a) (no-nl-p b))))

;;; ===========================================================================
;;; Obligation 1: compositional law (string-width is a LEFT FOLD of char-width)
;;;   width of (a ++ b) starting at col c = width of b starting at the width of a
;;;   from c.  This IS the additive/fold formulation the spec asks for.
;;; ===========================================================================

(defthm k-string-width-append
  (equal (k-string-width (append a b) col tab-size amb-width)
         (k-string-width b
                         (k-string-width a col tab-size amb-width)
                         tab-size amb-width)))

;; Prefix width <= whole width, stated over an explicit split (a ++ b): the
;; monotonicity obligation, via the fold law + column monotonicity of the suffix.
(defthm k-string-width-prefix-le
  (implies (and (natp col) (natp amb-width) (posp tab-size)
                (no-nl-p (append a b)))
           (<= (k-string-width a col tab-size amb-width)
               (k-string-width (append a b) col tab-size amb-width)))
  :hints (("Goal" :in-theory (disable k-string-width-monotone-col)
           :use ((:instance k-string-width-monotone-col
                            (codes b)
                            (col (k-string-width a col tab-size amb-width)))))))

;;; ===========================================================================
;;; Control-recursion -> +length collapse (header witness)
;;;   Production displays a control char as its *char-replacement* string and
;;;   recurses char-width over it.  Every replacement glyph is narrow, so the
;;;   recursion's result is col + (len replacement) -- which is what
;;;   `k-control-len' returns.  `narrow-run' models the recursion; the theorem
;;;   shows it equals + length.
;;; ===========================================================================

(defun narrow-run (codes col tab-size amb-width)
  (if (atom codes)
      col
      (narrow-run (cdr codes)
                  (k-char-width (car codes) col tab-size nil amb-width)
                  tab-size amb-width)))

(defthm narrow-code-width-is-plus1
  (implies (narrow-code-p code)
           (equal (k-char-width code col tab-size nil amb-width)
                  (+ col 1))))

(defthm narrow-run-is-plus-len
  (implies (and (natp col) (all-narrow-p codes))
           (equal (narrow-run codes col tab-size amb-width)
                  (+ col (len codes)))))

;;; ===========================================================================
;;; Obligation 3: wide-index Galois / least-index property
;;;   Production convention (see k-wide-index): the returned offset i is the
;;;   GREATEST index whose cumulative prefix width is <= goal, and NIL exactly
;;;   when goal is never exceeded (the whole run fits).  Stated as three facts,
;;;   all under the loop invariant (<= col goal) that the shell establishes by
;;;   starting at col = 0 with a natural goal.
;;; ===========================================================================

;; (a) When it returns an index, the width of that many characters is within
;;     goal -- i is a FEASIBLE prefix length.
(defthm k-wide-index-prefix-within
  (implies (and (natp col) (natp amb-width) (natp tab-size)
                (natp goal) (<= col goal)
                (k-wide-index codes goal col tab-size amb-width))
           (<= (k-string-width
                (k-take (k-wide-index codes goal col tab-size amb-width) codes)
                col tab-size amb-width)
               goal))
  :hints (("Goal" :in-theory (disable k-char-width)
           :induct (k-wide-index codes goal col tab-size amb-width))))

;; (b) One more character exceeds goal -- i is the GREATEST feasible prefix
;;     length (nothing longer fits).
(defthm k-wide-index-next-exceeds
  (implies (and (natp col) (natp amb-width) (natp tab-size)
                (k-wide-index codes goal col tab-size amb-width))
           (< goal
              (k-string-width
               (k-take (+ 1 (k-wide-index codes goal col tab-size amb-width)) codes)
               col tab-size amb-width)))
  :hints (("Goal" :in-theory (disable k-char-width)
           :induct (k-wide-index codes goal col tab-size amb-width))))

;; (c) Returns an index EXACTLY when goal is exceeded by the whole run (else NIL)
;;     -- the Galois connection with k-string-width for newline-free input.
(defthm k-wide-index-nil-iff
  (implies (and (natp col) (natp amb-width) (posp tab-size)
                (natp goal) (<= col goal) (no-nl-p codes))
           (iff (k-wide-index codes goal col tab-size amb-width)
                (< goal (k-string-width codes col tab-size amb-width))))
  :hints (("Goal" :in-theory (disable k-char-width)
           :induct (k-wide-index codes goal col tab-size amb-width))))
