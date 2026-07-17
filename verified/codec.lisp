;;;; verified/codec.lisp -- EOL/encoding codec kernel (SPEC-VK VK-5).
;;;;
;;;; One source of truth (SPEC-VK Constraint 2): this same file is certified by
;;;; ACL2 (scripts/run-proofs.sh) AND loaded verbatim into the Lem SBCL image
;;;; through verified/shim.lisp.
;;;;
;;;; WHAT THIS MODELS -- and the DOCUMENTED SCOPING DEVIATION from the spec text.
;;;;   SPEC-VK VK-5 states the codec "over octet lists".  This book instead models
;;;;   the END-OF-LINE layer over DECODED CODEPOINTS (naturals), NOT raw octets.
;;;;   Justification (design brief VK-5, recorded here + in verified/README.md +
;;;;   the tracking issue per Constraint 5):
;;;;     * Production's read path is (external-format decode) THEN end-of-line
;;;;       handling on the decoded characters (src/buffer/file.lisp %encoding-read,
;;;;       which runs `read-line' over an already-utf-8-decoded stream).  The EOL
;;;;       logic is a post-decode, codepoint-level transformation.
;;;;     * Modeling raw octets would re-verify SBCL's UTF-8 decoder, which is part
;;;;       of the trust base (SBCL itself -- README "Trust base").  Byte-level
;;;;       UTF-8 correctness is SBCL's job, not this kernel's.
;;;;     * The spec's ACTUAL intent -- DS-6 EOL correctness, "opening then saving a
;;;;       file must never delete a character" (tests/eol-roundtrip.lisp) -- is
;;;;       preserved exactly: the theorems below establish round-trip byte-identity
;;;;       of the codepoint stream for single-EOL input and no-character-loss for
;;;;       arbitrary (mixed) input.
;;;;   The differential PBT (tests/pbt/codec-conformance.lisp) closes the gap to
;;;;   real octets: it feeds generated UTF-8 byte files through the ACTUAL
;;;;   production read/write path and compares the resulting buffer against this
;;;;   kernel's prediction, so the codepoint-level model is pinned to production's
;;;;   full byte-level behavior.
;;;;
;;;; PRODUCTION SEMANTICS MIRRORED (post-DS-6):
;;;;   READ  (src/buffer/file.lisp %encoding-read, lines 38-72): `read-line' splits
;;;;     the decoded stream on LF (codepoint 10) only.  For end-of-line = :crlf a
;;;;     trailing CR is stripped from each newline-terminated line ONLY when
;;;;     actually present; a newline-terminated line lacking that CR is an LF-only
;;;;     line -> the file is flagged MIXED (save-time normalization is announced).
;;;;     The final read-line segment at EOF (no trailing LF) is inserted VERBATIM
;;;;     (no CR stripping, never flags mixed).  For :lf and :cr no CR stripping and
;;;;     no mixed detection occur (a genuine CR-separated file has no LF, so
;;;;     `read-line' returns it as one verbatim line -- faithfully reproduced).
;;;;   WRITE (src/buffer/file.lisp %write-region-to-file, lines 195-209): each line
;;;;     is emitted followed by the uniform EOL sequence (:crlf -> CR LF, :lf -> LF,
;;;;     :cr -> CR), EXCEPT the last line which gets no trailing separator.
;;;;
;;;; REPRESENTATION (VK-1's): text is a list of codepoints (naturals); 10 = LF,
;;;;   13 = CR.  A "line" is a codepoint list without 10 (VK-1 `linep'/`line-listp',
;;;;   reused from buffer-model for the totality/wf theorem).  ACL2 strings/chars
;;;;   are 8-bit and are NEVER used here.
;;;;
;;;; EXEC PATH (functions the shim-loaded shell actually calls): `decode-eol',
;;;;   `encode-eol' and their transitive callees (`decode-lines', `strip-eols',
;;;;   `split-on-nl', `crlf-mixed-p', `join-with', `eol-seq').  These use only CL
;;;;   homonyms (cond/if/eq/eql/atom/consp/car/cdr/cadr/cddr/cons/append/list) --
;;;;   NO shim whitelist entry is needed for VK-5.  All other defuns
;;;;   (`expand', `strip-eols'-siblings, `crlf-clean-p', predicates) are
;;;;   proof-only; they load harmlessly in-image but are not on the exec path.

(in-package "ACL2")

(include-book "buffer-model")

;; Lemma library for arithmetic normalization (proof-only: local, so nothing
;; from it is exec-reachable or exported by this book).
(local (include-book "arithmetic/top-with-meta" :dir :system))

;;; ===========================================================================
;;; Codepoint lists and eol kinds
;;; ===========================================================================

;; A codepoint list: a true-list of naturals.  Unlike VK-1 `linep', 10 (LF) IS
;; allowed -- these are whole files / buffer contents, not single lines.
(defun cp-listp (l)
  (if (atom l)
      (null l)
      (and (natp (car l))
           (cp-listp (cdr l)))))

(defun eol-kindp (eol)
  (or (eq eol :lf)
      (eq eol :crlf)
      (eq eol :cr)))

;; Membership by value (used only in the :cr round-trip hypothesis).
(defun mem (x l)
  (if (atom l)
      nil
      (or (eql x (car l))
          (mem x (cdr l)))))

;;; ===========================================================================
;;; strip-eols -- the READ transform: decoded codepoints -> buffer content
;;; ===========================================================================

;; Produce the buffer CONTENT codepoints from the decoded input CS under EOL.
;; For :crlf, drop the CR of each CRLF pair (the "strip only when present" of
;; %encoding-read); every other codepoint -- including lone CRs and all LFs --
;; is kept.  For :lf and :cr this is the identity on proper lists (production
;; inserts each read-line segment verbatim).  This is exactly the sequence
;; %encoding-read inserts into the buffer.
(defun strip-eols (cs eol)
  (cond ((atom cs) nil)
        ((and (eq eol :crlf)
              (eql (car cs) 13)
              (consp (cdr cs))
              (eql (cadr cs) 10))
         ;; CR immediately before LF: drop the CR, keep the following LF.
         (strip-eols (cdr cs) eol))
        (t (cons (car cs) (strip-eols (cdr cs) eol)))))

;;; ===========================================================================
;;; split-on-nl -- split the buffer content into lines on LF (codepoint 10)
;;; ===========================================================================

;; Standard split on 10: k+1 pieces for k newlines; always at least one piece
;; (a trailing 10 yields a trailing empty line, matching a real buffer's line
;; list).  Same shape as VK-2 `split-lf'.
(defun split-on-nl (cs)
  (if (atom cs)
      (list nil)
      (if (eql (car cs) 10)
          (cons nil (split-on-nl (cdr cs)))
          (let ((rest (split-on-nl (cdr cs))))
            (cons (cons (car cs) (car rest)) (cdr rest))))))

;;; ===========================================================================
;;; crlf-mixed-p -- production's mixed-eol flag (only meaningful for :crlf)
;;; ===========================================================================

;; True iff some LF is NOT the LF of a CRLF pair (a bare LF), i.e. exactly when
;; %encoding-read's :crlf branch would set mixed-eol-p.  A CRLF pair is consumed
;; two-at-a-time; any 10 reached otherwise is a bare LF.  (The EOF segment has
;; no LF, so it never flags mixed -- matching production's eof branch.)
(defun crlf-mixed-p (cs)
  (cond ((atom cs) nil)
        ((eql (car cs) 10) t)
        ((and (eql (car cs) 13)
              (consp (cdr cs))
              (eql (cadr cs) 10))
         (crlf-mixed-p (cddr cs)))
        (t (crlf-mixed-p (cdr cs)))))

;;; ===========================================================================
;;; decode-eol -- EXEC entry: (mv lines mixed-p)
;;; ===========================================================================

(defun decode-lines (cs eol)
  (split-on-nl (strip-eols cs eol)))

(defun decode-eol (cs eol)
  ;; mixed is only ever reported for :crlf (production sets mixed-eol-p only in
  ;; its :crlf branch); :lf and :cr never announce normalization.
  (mv (decode-lines cs eol)
      (if (eq eol :crlf)
          (crlf-mixed-p cs)
          nil)))

;;; ===========================================================================
;;; encode-eol -- EXEC entry: lines -> codepoints (uniform EOL emission)
;;; ===========================================================================

(defun eol-seq (eol)
  (cond ((eq eol :crlf) (list 13 10))
        ((eq eol :cr) (list 13))
        (t (list 10))))

;; Join LINES with SEP between them; the last line gets no trailing separator
;; (matching %write-region-to-file's `unless eof-p' guard).  Same shape as VK-2
;; `join-lf' but with a multi-codepoint separator.
(defun join-with (lines sep)
  (if (atom lines)
      nil
      (if (atom (cdr lines))
          (car lines)
          (append (car lines) (append sep (join-with (cdr lines) sep))))))

(defun encode-eol (lines eol)
  (join-with lines (eol-seq eol)))

;;; ===========================================================================
;;; Proof-only functions
;;; ===========================================================================

;; expand Y by replacing each LF (10) with SEP.  join-with o split-on-nl = this.
(defun expand (y sep)
  (cond ((atom y) nil)
        ((eql (car y) 10) (append sep (expand (cdr y) sep)))
        (t (cons (car y) (expand (cdr y) sep)))))

;; The canonical flatten (VK-2 `k-flatten' shape): lines joined by single LFs.
(defun flatten-lines (lines)
  (join-with lines (list 10)))

;; Remove every LF (line separator) -- used to state content-only preservation.
(defun drop-nl (xs)
  (cond ((atom xs) nil)
        ((eql (car xs) 10) (drop-nl (cdr xs)))
        (t (cons (car xs) (drop-nl (cdr xs))))))

;; The NON-EOL codepoints of CS in order: drop every LF and, for :crlf, the CR
;; of each CRLF pair (lone CRs are content and are kept).  This is the spec's
;; "sequence of non-EOL codepoints"; the no-char-loss theorem shows the decoded
;; line contents concatenate to exactly this.
(defun content-codepoints (cs eol)
  (cond ((atom cs) nil)
        ((and (eq eol :crlf)
              (eql (car cs) 13)
              (consp (cdr cs))
              (eql (cadr cs) 10))
         (content-codepoints (cddr cs) eol))   ; drop CR and its LF together
        ((eql (car cs) 10)
         (content-codepoints (cdr cs) eol))     ; drop the LF
        (t (cons (car cs) (content-codepoints (cdr cs) eol)))))

;; The precise "single-EOL-clean for :crlf" predicate: every LF is the LF of a
;; CRLF pair (no bare LF).  Equivalent to (not (crlf-mixed-p cs)); the two-at-a-
;; time recursion is shared with crlf-mixed-p and strip-eols so the round-trip
;; induction lines up.  Covers CRLF files with AND without a trailing newline.
(defun crlf-clean-p (cs)
  (cond ((atom cs) t)
        ((eql (car cs) 10) nil)                 ; a bare LF: not clean
        ((and (eql (car cs) 13)
              (consp (cdr cs))
              (eql (cadr cs) 10))
         (crlf-clean-p (cddr cs)))              ; consume a CRLF pair
        (t (crlf-clean-p (cdr cs)))))           ; consume one non-LF codepoint

;; Unified "single-EOL-clean" input predicate for the round-trip theorem:
;;   :lf   -> always (LF split/join are exact inverses for any codepoint list)
;;   :cr   -> no LF present (a genuine CR-separated file has no LF; production
;;            reads it as one verbatim line, and write re-emits it unchanged)
;;   :crlf -> crlf-clean-p (no bare LF, i.e. not mixed)
(defun single-eol-clean-p (cs eol)
  (cond ((eq eol :crlf) (crlf-clean-p cs))
        ((eq eol :cr) (not (mem 10 cs)))
        (t t)))

;;; ===========================================================================
;;; Lemma library
;;; ===========================================================================

(defthm append-assoc
  (equal (append (append a b) c)
         (append a (append b c))))

(defthm true-listp-of-strip-eols
  (true-listp (strip-eols cs eol)))

(defthm consp-of-split-on-nl
  (consp (split-on-nl cs)))

;; join-with distributes a leading codepoint out of the first piece.
(defthm join-with-cons-car
  (equal (join-with (cons (cons c a) more) sep)
         (cons c (join-with (cons a more) sep))))

;; The key structural bridge: join-with o split-on-nl replaces each LF with SEP.
(defthm join-with-split-on-nl
  (equal (join-with (split-on-nl y) sep)
         (expand y sep)))

;; expand with the single-LF separator is the identity on proper lists.
(defthm expand-nl-identity
  (implies (true-listp y)
           (equal (expand y (list 10)) y)))

;; flatten o decode = strip-eols: the flattened decoded lines are exactly the
;; buffer content, so nothing is added, dropped, or reordered.
(defthm flatten-lines-of-decode-lines
  (equal (flatten-lines (decode-lines cs eol))
         (strip-eols cs eol)))

;;; ===========================================================================
;;; VK-5 obligation 3: totality / well-formedness
;;;   decode always yields a wf line list (VK-1 `line-listp': nat-lists, no 10)
;;;   for codepoint-list input.  (decode-eol / encode-eol are TOTAL by ACL2
;;;   admission -- defined and terminating on every input.)
;;; ===========================================================================

(defthm cp-listp-of-strip-eols
  (implies (cp-listp cs)
           (cp-listp (strip-eols cs eol))))

(defthm linep-of-car-of-line-listp
  (implies (line-listp l)
           (linep (car l))))

(defthm line-listp-of-cdr-line-listp
  (implies (line-listp l)
           (line-listp (cdr l))))

(defthm line-listp-of-split-on-nl
  (implies (cp-listp y)
           (line-listp (split-on-nl y))))

(defthm line-listp-of-decode-lines
  (implies (cp-listp cs)
           (line-listp (decode-lines cs eol))))

;; decode always yields at least one line (a real buffer always has >= 1 line).
(defthm consp-of-decode-lines
  (consp (decode-lines cs eol)))

;;; ===========================================================================
;;; VK-5 obligation 2: no-character-loss for arbitrary (mixed) input
;;; ===========================================================================

;; Primary form (spec wording): strip-eols(cs) = flatten(decode lines).
(defthm no-char-loss
  (equal (flatten-lines (decode-lines cs eol))
         (strip-eols cs eol)))

;; Content-only form (the teeth): the concatenation of the decoded line
;; CONTENTS (separators removed) equals the input with every EOL codepoint
;; stripped, in order -- every non-EOL codepoint of the input appears in the
;; output exactly once, in order, for ANY input and ANY eol.
(defthm drop-nl-of-strip-eols
  (equal (drop-nl (strip-eols cs eol))
         (content-codepoints cs eol))
  :hints (("Goal" :induct (content-codepoints cs eol))))

(defthm no-char-loss-content
  (equal (drop-nl (flatten-lines (decode-lines cs eol)))
         (content-codepoints cs eol)))

;;; ===========================================================================
;;; VK-5 obligation 1: round-trip byte-identity for single-EOL input
;;;   encode-eol(decode-lines(cs, eol), eol) = cs
;;; for cs single-EOL-clean for eol -- LF/CRLF/CR, with and without a trailing
;;; line break.
;;; ===========================================================================

;; --- :lf : identity for ANY codepoint list (LF is the split/join separator) ---

(defthm strip-eols-lf-identity
  (implies (true-listp cs)
           (equal (strip-eols cs :lf) cs)))

(defthm round-trip-lf
  (implies (true-listp cs)
           (equal (encode-eol (decode-lines cs :lf) :lf) cs)))

;; --- :cr : identity when no LF is present (a genuine CR-separated file) ---

(defthm strip-eols-cr-identity
  (implies (true-listp cs)
           (equal (strip-eols cs :cr) cs)))

(defthm split-on-nl-of-no-nl
  (implies (and (true-listp cs) (not (mem 10 cs)))
           (equal (split-on-nl cs) (list cs))))

(defthm join-with-singleton
  (equal (join-with (list x) sep) x))

(defthm round-trip-cr
  (implies (and (true-listp cs) (not (mem 10 cs)))
           (equal (encode-eol (decode-lines cs :cr) :cr) cs)))

;; --- :crlf : identity when clean (every LF is a CRLF, i.e. not mixed) ---

(defthm expand-strip-eols-crlf
  (implies (and (true-listp cs) (crlf-clean-p cs))
           (equal (expand (strip-eols cs :crlf) (list 13 10)) cs))
  :hints (("Goal" :induct (crlf-clean-p cs))))

(defthm round-trip-crlf
  (implies (and (true-listp cs) (crlf-clean-p cs))
           (equal (encode-eol (decode-lines cs :crlf) :crlf) cs)))

;; --- unified statement over single-eol-clean-p ---

(defthm round-trip-single-eol-clean
  (implies (and (true-listp cs)
                (eol-kindp eol)
                (single-eol-clean-p cs eol))
           (equal (encode-eol (decode-lines cs eol) eol) cs))
  :hints (("Goal" :in-theory (disable encode-eol decode-lines)
           :cases ((eq eol :lf) (eq eol :cr) (eq eol :crlf)))))

;;; ===========================================================================
;;; Mixed-flag characterization (ties the reported flag to production truth)
;;; ===========================================================================

;; crlf-clean-p is exactly the negation of the mixed flag.
(defthm crlf-clean-p-iff-not-mixed
  (equal (crlf-clean-p cs)
         (not (crlf-mixed-p cs))))

;; A clean CRLF file is never reported mixed (no false normalization notice).
(defthm decode-eol-not-mixed-when-clean
  (implies (crlf-clean-p cs)
           (not (mv-nth 1 (decode-eol cs :crlf)))))

;; :lf and :cr decode never report mixed (matches production: only the :crlf
;; branch of %encoding-read ever sets mixed-eol-p).
(defthm decode-eol-lf-not-mixed
  (not (mv-nth 1 (decode-eol cs :lf))))

(defthm decode-eol-cr-not-mixed
  (not (mv-nth 1 (decode-eol cs :cr))))
