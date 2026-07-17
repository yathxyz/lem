;;;; verified/buffer-edit.lisp -- Edit primitives + marker algebra (SPEC-VK VK-2).
;;;;
;;;; One source of truth (SPEC-VK Constraint 2): this same file is certified by
;;;; ACL2 (scripts/run-proofs.sh) AND loaded verbatim into the Lem SBCL image
;;;; through verified/shim.lisp.
;;;;
;;;; The two edit primitives are faithful pure transcriptions of production:
;;;;   k-insert  <->  insert-string/point  (src/buffer/internal/buffer-insert.lisp:99-119)
;;;;   k-delete  <->  delete-char/point    (src/buffer/internal/buffer-insert.lisp:121-150)
;;;; and the marker relocation transcribes shift-markers' EXACT four cases
;;;; (src/buffer/internal/buffer-insert.lisp:39-97):
;;;;   case 1: same-line insert   (offset-line = 0, offset-char > 0)
;;;;   case 2: multi-line insert  (offset-line > 0)
;;;;   case 3: same-line delete   (offset-line = 0, offset-char < 0)
;;;;   case 4: multi-line delete  (offset-line < 0)
;;;; including the boundary kind semantics: a :left-inserting point AT the
;;;; insertion position moves, a :right-inserting one stays (for delete the
;;;; relocation is kind-independent, as in production). Production calls
;;;; shift-markers exactly once per edit, with the editing point's coordinates
;;;; unchanged by the line-level splicing (line functions never touch points),
;;;; so a single pure point-map per edit is the faithful model.
;;;;
;;;; Positions: production position-at-point (src/buffer/internal/basic.lisp:382-387)
;;;; is 1-based; each line before the point contributes (line-length + 1) -- the
;;;; virtual LF. k-position / k-point-at-position transcribe that algebra.
;;;; k-shift-position-insert / k-shift-position-delete transcribe
;;;; compute-edit-offset (src/buffer/internal/edit.lisp:40-51).
;;;;
;;;; Text representation is VK-1's: lines are nat-lists without 10; an insert
;;;; payload is a nat-list that MAY contain 10 (= line break). k-delete returns
;;;; (mv buffer' deleted) where deleted uses 10 for the line breaks it consumed,
;;;; mirroring delete-char/point's killring string.
;;;;
;;;; Tick: +1 per edit, matching production buffer-modify in :edit mode
;;;; (src/buffer/internal/undo.lisp:47-53); the full +-1 undo semantics is VK-3.
;;;;
;;;; EXEC PATH uses only CL homonyms + the shim whitelist {natp, len,
;;;; true-listp} + mv/mv-let (verified/shim.lisp) + functions defined in this
;;;; book and buffer-model.lisp. std/ community books, when included, are
;;;; local lemma libraries only -- nothing from them is exec-reachable.

(in-package "ACL2")

(include-book "buffer-model")

;; Lemma library for linear-arithmetic normalization (proof-only: local, so
;; nothing from it is exec-reachable or exported by this book).
(local (include-book "arithmetic/top-with-meta" :dir :system))

;;; ===========================================================================
;;; List helpers (own definitions: ACL2's take pads with nil, CL has no take;
;;; these are total, stop at the end of the list, and are exec-reachable)
;;; ===========================================================================

(defun k-take (n l)
  (declare (xargs :measure (acl2-count l)))
  (if (and (consp l) (< 0 n))
      (cons (car l) (k-take (- n 1) (cdr l)))
      nil))

(defun k-drop (n l)
  (declare (xargs :measure (acl2-count l)))
  (if (and (consp l) (< 0 n))
      (k-drop (- n 1) (cdr l))
      l))

;;; Split a payload on codepoint 10 into segments (production
;;; insert-string/point splits its string on #\newline). Always returns at
;;; least one segment; k+1 segments for k newlines.

(defun split-lf (l)
  (declare (xargs :measure (acl2-count l)))
  (if (atom l)
      (list nil)
      (if (eql (car l) 10)
          (cons nil (split-lf (cdr l)))
          (let ((rest (split-lf (cdr l))))
            (cons (cons (car l) (car rest)) (cdr rest))))))

(defun join-lf (segs)
  (if (atom segs)
      nil
      (if (atom (cdr segs))
          (car segs)
          (append (car segs) (cons 10 (join-lf (cdr segs)))))))

(defun last-seg (segs)
  (if (consp (cdr segs))
      (last-seg (cdr segs))
      (car segs)))

;;; A payload is a nat-list; 10 is allowed (it is the line separator).
(defun payloadp (l)
  (if (atom l)
      (null l)
      (and (natp (car l))
           (payloadp (cdr l)))))

;;; ===========================================================================
;;; Flattened content: buffer text as one codepoint list with 10 between lines
;;; ===========================================================================

(defun k-flatten (lines)
  (if (atom lines)
      nil
      (if (atom (cdr lines))
          (car lines)
          (append (car lines) (cons 10 (k-flatten (cdr lines)))))))

;; Flatten of the first J lines, each followed by its 10 separator.
(defun k-flatten-n (lines j)
  (if (and (consp lines) (< 0 j))
      (append (car lines) (cons 10 (k-flatten-n (cdr lines) (- j 1))))
      nil))

;; Number of codepoints contributed by the first J lines (each len + 1).
(defun flat-len-before (lines j)
  (if (and (consp lines) (< 0 j))
      (+ 1 (len (car lines)) (flat-len-before (cdr lines) (- j 1)))
      0))

;;; ===========================================================================
;;; Position <-> point conversion (production position-at-point semantics:
;;; 1-based, each earlier line contributes len+1)
;;; ===========================================================================

(defun k-position (lines linum charpos)
  (+ 1 charpos (flat-len-before lines (- linum 1))))

(defun k-point-at-position (lines pos)
  (declare (xargs :measure (acl2-count lines)))
  (if (or (atom (cdr lines))
          (<= (- pos 1) (len (car lines))))
      (mv 1 (- pos 1))
      (mv-let (l c)
          (k-point-at-position (cdr lines) (- pos (+ 1 (len (car lines)))))
        (mv (+ 1 l) c))))

;;; ===========================================================================
;;; Marker relocation: shift-markers' four cases as pure point maps
;;; ===========================================================================

(defun mk-pt (id linum charpos kind)
  (list id linum charpos kind))

;; The kind-conditional boundary test of shift-markers cases 1 and 2:
;; :left-inserting moves when the insert is at or before it (<=),
;; :right-inserting only when strictly before it (<).
(defun insert-shifts-p (p charpos)
  (if (eq (pt-kind p) :left-inserting)
      (<= charpos (pt-charpos p))
      (< charpos (pt-charpos p))))

(defun shift-point-insert (p linum charpos offset-line offset-char)
  (cond ((and (= offset-line 0) (< 0 offset-char))
         ;; shift-markers case 1: same-line insert, points on the line only
         (if (and (= (pt-linum p) linum)
                  (insert-shifts-p p charpos))
             (mk-pt (pt-id p)
                    (pt-linum p)
                    (+ (pt-charpos p) offset-char)
                    (pt-kind p))
             p))
        ((< 0 offset-line)
         ;; shift-markers case 2: multi-line insert, all points
         (cond ((and (= (pt-linum p) linum)
                     (insert-shifts-p p charpos))
                (mk-pt (pt-id p)
                       (+ (pt-linum p) offset-line)
                       (+ (- (pt-charpos p) charpos) offset-char)
                       (pt-kind p)))
               ((< linum (pt-linum p))
                (mk-pt (pt-id p)
                       (+ (pt-linum p) offset-line)
                       (pt-charpos p)
                       (pt-kind p)))
               (t p)))
        (t p)))

(defun shift-point-delete-same-line (p linum charpos oc)
  ;; shift-markers case 3: same-line delete of OC chars at CHARPOS
  ;; (kind-independent; charpos clamps at the deletion start)
  (if (and (< 0 oc)
           (= (pt-linum p) linum)
           (< charpos (pt-charpos p)))
      (mk-pt (pt-id p)
             (pt-linum p)
             (if (> charpos (- (pt-charpos p) oc))
                 charpos
                 (- (pt-charpos p) oc))
             (pt-kind p))
      p))

(defun shift-point-delete-multi (p linum charpos k oc)
  ;; shift-markers case 4: delete crossing K lines, OC chars consumed from the
  ;; last touched line (kind-independent)
  (if (or (< linum (pt-linum p))
          (and (= linum (pt-linum p))
               (<= charpos (pt-charpos p))))
      (if (<= (- (pt-linum p) k) linum)
          (mk-pt (pt-id p)
                 linum
                 (if (= (- (pt-linum p) k) linum)
                     (+ charpos (max 0 (- (pt-charpos p) oc)))
                     charpos)
                 (pt-kind p))
          (mk-pt (pt-id p)
                 (- (pt-linum p) k)
                 (pt-charpos p)
                 (pt-kind p)))
      p))

;; Dispatcher matching production's single shift-markers call for a delete:
;; K merges and OC chars from the last touched line give shift-markers
;; (-K, -OC); K > 0 selects case 4, K = 0 with OC > 0 case 3, both zero no-op.
(defun shift-point-delete (p linum charpos k oc)
  (if (< 0 k)
      (shift-point-delete-multi p linum charpos k oc)
      (shift-point-delete-same-line p linum charpos oc)))

(defun shift-points-insert (points linum charpos offset-line offset-char)
  (if (atom points)
      nil
      (cons (shift-point-insert (car points) linum charpos offset-line offset-char)
            (shift-points-insert (cdr points) linum charpos offset-line offset-char))))

(defun shift-points-delete (points linum charpos k oc)
  (if (atom points)
      nil
      (cons (shift-point-delete (car points) linum charpos k oc)
            (shift-points-delete (cdr points) linum charpos k oc))))

;;; ===========================================================================
;;; k-insert
;;; ===========================================================================

;; The new lines replacing the target line: production splits the target at
;; charpos into prefix|suffix, puts segment 0 after prefix, middle segments on
;; their own lines, and the last segment before suffix.
(defun make-inserted-rest (segs suffix)
  (if (atom (cdr segs))
      (list (append (car segs) suffix))
      (cons (car segs)
            (make-inserted-rest (cdr segs) suffix))))

(defun make-inserted-lines (prefix segs suffix)
  (if (atom (cdr segs))
      (list (append prefix (car segs) suffix))
      (cons (append prefix (car segs))
            (make-inserted-rest (cdr segs) suffix))))

(defun insert-into-lines (lines linum charpos payload)
  (let* ((target (nth-line (- linum 1) lines))
         (prefix (k-take charpos target))
         (suffix (k-drop charpos target)))
    (append (k-take (- linum 1) lines)
            (make-inserted-lines prefix (split-lf payload) suffix)
            (k-drop linum lines))))

(defun k-insert (b linum charpos payload)
  (let* ((segs (split-lf payload))
         (offset-line (- (len segs) 1))    ; number of newlines in payload
         (offset-char (len (last-seg segs)))) ; length of the final segment
    (list (insert-into-lines (buf-lines b) linum charpos payload)
          (shift-points-insert (buf-points b) linum charpos offset-line offset-char)
          (+ 1 (buf-tick b)))))

;;; ===========================================================================
;;; k-delete
;;; ===========================================================================

;; Transcription of delete-char/point's loop over the tail of the line list
;; starting at the target line. Returns
;;   (mv new-tail deleted nmerges end-offset-char)
;; where nmerges = number of merged lines (production's -offset-line) and
;; end-offset-char = magnitude of the final shift-markers offset-char:
;;   - fits in line (not eolp):            N            [shift (0, -N)]
;;   - runs off the end of the buffer:     avail        [shift (-j, charpos-len)]
;;   - deletion ends exactly at a newline: 0            [finally: shift (-j, 0)]
(defun k-delete-lines (ls charpos n)
  (declare (xargs :measure (len ls)))
  (if (or (atom ls) (not (integerp n)) (<= n 0))
      (mv ls nil 0 0)
      (let* ((target (car ls))
             (avail (- (len target) charpos)))
        (cond ((<= n avail)
               ;; (not eolp): the deletion fits in the current line
               (mv (cons (append (k-take charpos target)
                                 (k-drop (+ charpos n) target))
                         (cdr ls))
                   (k-take n (k-drop charpos target))
                   0
                   n))
              ((atom (cdr ls))
               ;; last line: delete to the end of the buffer
               (mv (list (k-take charpos target))
                   (k-drop charpos target)
                   0
                   avail))
              (t
               ;; merge-with-next-line, then keep deleting from CHARPOS
               (mv-let (rest deleted j oc)
                   (k-delete-lines (cons (append (k-take charpos target)
                                                 (car (cdr ls)))
                                         (cdr (cdr ls)))
                                   charpos
                                   (- n (+ avail 1)))
                 (mv rest
                     (append (k-drop charpos target) (cons 10 deleted))
                     (+ 1 j)
                     oc)))))))

(defun k-delete (b linum charpos n)
  (mv-let (new-tail deleted j oc)
      (k-delete-lines (k-drop (- linum 1) (buf-lines b)) charpos n)
    (mv (list (append (k-take (- linum 1) (buf-lines b)) new-tail)
              (shift-points-delete (buf-points b) linum charpos j oc)
              (+ 1 (buf-tick b)))
        deleted)))

;;; ===========================================================================
;;; Offset algebra: compute-edit-offset (src/buffer/internal/edit.lisp:40-51)
;;; ===========================================================================

(defun k-shift-position-insert (dest src length)
  ;; :insert-string branch: positions at or after the insert move right.
  (if (<= src dest)
      (+ dest length)
      dest))

(defun k-shift-position-delete (dest src length)
  ;; :delete-string branch: positions strictly after the delete move left,
  ;; first clamped at 1, then clamped up to the deletion start.
  (if (< src dest)
      (let ((d (max 1 (- dest length))))
        (if (< d src)
            src
            d))
      dest))

;;; A valid edit location in buffer B (1-based linum, 0-based charpos at most
;;; the target line's length) -- the hypothesis under which the edit theorems
;;; are stated; production always edits at such positions.
(defun edit-locp (b linum charpos)
  (and (natp linum)
       (<= 1 linum)
       (<= linum (len (buf-lines b)))
       (natp charpos)
       (<= charpos (len (nth-line (- linum 1) (buf-lines b))))))

;;; ===========================================================================
;;; Lemma library: k-take / k-drop / append
;;; ===========================================================================

(defthm append-assoc
  (equal (append (append a b) c)
         (append a (append b c))))

(defthm true-listp-of-k-take
  (true-listp (k-take n l)))

(defthm len-of-append
  (equal (len (append a b))
         (+ (len a) (len b))))

(defthm len-of-k-take
  (implies (and (natp n) (<= n (len l)))
           (equal (len (k-take n l)) n)))

(defthm len-of-k-drop
  (implies (and (natp n) (<= n (len l)))
           (equal (len (k-drop n l)) (- (len l) n))))

(defthm k-take-whole
  (implies (true-listp l)
           (equal (k-take (len l) l) l)))

(defthm k-drop-whole
  (implies (true-listp l)
           (equal (k-drop (len l) l) nil)))

(defthm k-take-k-drop-append
  (implies (true-listp l)
           (equal (append (k-take n l) (k-drop n l)) l)))

(defthm k-take-of-append-exact
  (implies (and (true-listp a) (natp n))
           (equal (k-take (+ (len a) n) (append a b))
                  (append a (k-take n b)))))

(defthm k-drop-of-append-exact
  (implies (natp n)
           (equal (k-drop (+ (len a) n) (append a b))
                  (k-drop n b))))

(defthm k-take-of-append-under
  (implies (and (natp n) (<= n (len a)))
           (equal (k-take n (append a b))
                  (k-take n a))))

(defthm k-drop-of-append-under
  (implies (and (natp n) (< n (len a)))
           (equal (k-drop n (append a b))
                  (append (k-drop n a) b))))

(defthm k-drop-of-k-drop
  (implies (and (natp m) (natp n))
           (equal (k-drop m (k-drop n l))
                  (k-drop (+ m n) l))))

;;; ===========================================================================
;;; Lemma library: split-lf / join-lf / last-seg
;;; ===========================================================================

(defthm consp-of-split-lf
  (consp (split-lf l)))

(defthm join-lf-of-split-lf
  (implies (true-listp l)
           (equal (join-lf (split-lf l)) l)))

(defthm line-listp-of-split-lf
  (implies (payloadp l)
           (line-listp (split-lf l))))

(defthm payloadp-forward-to-true-listp
  (implies (payloadp l)
           (true-listp l))
  :rule-classes (:rewrite :forward-chaining))

;;; ===========================================================================
;;; Lemma library: linep / line-listp closure
;;; ===========================================================================

(defthm linep-forward-to-true-listp
  (implies (linep l)
           (true-listp l))
  :rule-classes (:rewrite :forward-chaining))

(defthm line-listp-forward-to-true-listp
  (implies (line-listp l)
           (true-listp l))
  :rule-classes (:rewrite :forward-chaining))

(defthm linep-of-append
  (implies (and (linep a) (linep b))
           (linep (append a b))))

(defthm linep-of-k-take
  (implies (linep l)
           (linep (k-take n l))))

(defthm linep-of-k-drop
  (implies (linep l)
           (linep (k-drop n l))))

(defthm line-listp-of-append
  (implies (and (line-listp a) (line-listp b))
           (line-listp (append a b))))

(defthm line-listp-of-k-take
  (implies (line-listp l)
           (line-listp (k-take n l))))

(defthm line-listp-of-k-drop
  (implies (line-listp l)
           (line-listp (k-drop n l))))

(defthm linep-of-nth-line
  (implies (line-listp ls)
           (linep (nth-line n ls))))

(defthm linep-of-last-seg
  (implies (line-listp segs)
           (linep (last-seg segs))))

(defthm linep-of-car-when-line-listp
  (implies (line-listp l)
           (linep (car l))))

(defthm line-listp-of-cdr
  (implies (line-listp l)
           (line-listp (cdr l))))

(defthm line-listp-of-make-inserted-rest
  (implies (and (line-listp segs) (linep suffix))
           (line-listp (make-inserted-rest segs suffix))))

(defthm line-listp-of-make-inserted-lines
  (implies (and (linep prefix) (line-listp segs) (linep suffix))
           (line-listp (make-inserted-lines prefix segs suffix))))

;;; ===========================================================================
;;; Lemma library: nth-line / last-line
;;; ===========================================================================

(defthm nth-line-of-append
  (implies (natp n)
           (equal (nth-line n (append a b))
                  (if (< n (len a))
                      (nth-line n a)
                      (nth-line (- n (len a)) b)))))

(defthm nth-line-of-k-drop
  (implies (and (natp n) (natp j))
           (equal (nth-line n (k-drop j l))
                  (nth-line (+ n j) l))))

(defthm nth-line-of-k-take
  (implies (and (natp n) (natp j) (< n j))
           (equal (nth-line n (k-take j l))
                  (nth-line n l))))

(defthm last-line-is-nth-line
  (implies (consp lines)
           (equal (last-line lines)
                  (nth-line (- (len lines) 1) lines))))

;;; ===========================================================================
;;; Structure of the inserted region
;;; ===========================================================================

(defthm len-of-make-inserted-rest
  (equal (len (make-inserted-rest segs suffix))
         (max 1 (len segs))))

(defthm len-of-make-inserted-lines
  (equal (len (make-inserted-lines prefix segs suffix))
         (max 1 (len segs))))

(defthm consp-of-make-inserted-lines
  (consp (make-inserted-lines prefix segs suffix)))

(defthm len-of-insert-into-lines
  (implies (and (line-listp lines)
                (natp linum) (<= 1 linum) (<= linum (len lines)))
           (equal (len (insert-into-lines lines linum charpos payload))
                  (+ (len lines) (- (len (split-lf payload)) 1)))))

(defthm len-of-split-lf-pos
  (<= 1 (len (split-lf l)))
  :rule-classes (:rewrite :linear))

(defthm consp-by-len
  (implies (< 0 (len l))
           (consp l)))

(defthm len-equal-0
  (equal (equal (len l) 0)
         (not (consp l))))

(defthm len-equal-0-alt
  (equal (equal 0 (len l))
         (not (consp l))))

;; Total characterization of the inserted region's lines: first line carries
;; the prefix, middle segments stand alone, the last segment carries the
;; suffix. Stated for every index so the rewriter never has to normalize an
;; index into a special syntactic form.
(defthm nth-line-of-make-inserted-rest-any
  (implies (and (natp i) (consp segs))
           (equal (nth-line i (make-inserted-rest segs suffix))
                  (cond ((< i (- (len segs) 1)) (nth-line i segs))
                        ((equal i (- (len segs) 1))
                         (append (last-seg segs) suffix))
                        (t nil)))))

(defthm nth-line-of-make-inserted-lines-any
  (implies (natp i)
           (equal (nth-line i (make-inserted-lines prefix segs suffix))
                  (cond ((atom (cdr segs))
                         (if (equal i 0)
                             (append prefix (car segs) suffix)
                             nil))
                        ((equal i 0) (append prefix (car segs)))
                        ((< i (- (len segs) 1)) (nth-line i segs))
                        ((equal i (- (len segs) 1))
                         (append (last-seg segs) suffix))
                        (t nil)))))

;;; ===========================================================================
;;; Shift-map basics: shape, id, kind preservation
;;; ===========================================================================

(defthm pt-id-of-shift-point-insert
  (equal (pt-id (shift-point-insert p linum charpos ol oc))
         (pt-id p)))

(defthm pt-kind-of-shift-point-insert
  (equal (pt-kind (shift-point-insert p linum charpos ol oc))
         (pt-kind p)))

(defthm pointp-of-shift-point-insert
  (implies (and (pointp p) (natp charpos) (natp ol) (natp oc))
           (pointp (shift-point-insert p linum charpos ol oc))))

(defthm pt-id-of-shift-point-delete
  (equal (pt-id (shift-point-delete p linum charpos k oc))
         (pt-id p)))

(defthm pt-kind-of-shift-point-delete
  (equal (pt-kind (shift-point-delete p linum charpos k oc))
         (pt-kind p)))

(defthm pointp-of-shift-point-delete
  (implies (and (pointp p) (natp linum) (<= 1 linum) (natp charpos)
                (natp k) (natp oc))
           (pointp (shift-point-delete p linum charpos k oc))))

(defthm points-listp-of-shift-points-insert
  (implies (and (points-listp points) (natp charpos) (natp ol) (natp oc))
           (points-listp (shift-points-insert points linum charpos ol oc))))

(defthm points-listp-of-shift-points-delete
  (implies (and (points-listp points) (natp linum) (<= 1 linum)
                (natp charpos) (natp k) (natp oc))
           (points-listp (shift-points-delete points linum charpos k oc))))

(defthm ids-of-of-shift-points-insert
  (equal (ids-of (shift-points-insert points linum charpos ol oc))
         (ids-of points)))

(defthm ids-of-of-shift-points-delete
  (equal (ids-of (shift-points-delete points linum charpos k oc))
         (ids-of points)))

(defthm find-point-of-shift-points-insert
  (implies (points-listp points)
           (equal (find-point id (shift-points-insert points linum charpos ol oc))
                  (if (find-point id points)
                      (shift-point-insert (find-point id points) linum charpos ol oc)
                      nil)))
  :hints (("Goal" :in-theory (disable shift-point-insert))))

(defthm find-point-of-shift-points-delete
  (implies (points-listp points)
           (equal (find-point id (shift-points-delete points linum charpos k oc))
                  (if (find-point id points)
                      (shift-point-delete (find-point id points) linum charpos k oc)
                      nil)))
  :hints (("Goal" :in-theory (disable shift-point-delete))))

;;; ===========================================================================
;;; wf-preservation, insert side (VK-2 obligation 1a)
;;; ===========================================================================

;; Any single in-bounds point stays in bounds after the insert relocation with
;; the offsets k-insert derives from the payload.
(defthm point-in-bounds-of-shift-point-insert
  (implies (and (line-listp lines)
                (pointp p)
                (point-in-bounds-p p lines)
                (natp linum) (<= 1 linum) (<= linum (len lines))
                (natp charpos)
                (<= charpos (len (nth-line (+ -1 linum) lines))))
           (point-in-bounds-p
            (shift-point-insert p linum charpos
                                (- (len (split-lf payload)) 1)
                                (len (last-seg (split-lf payload))))
            (insert-into-lines lines linum charpos payload)))
  :hints (("Goal" :do-not-induct t)))

(defthm points-in-bounds-of-shift-points-insert
  (implies (and (line-listp lines)
                (points-listp points)
                (points-in-bounds-p points lines)
                (natp linum) (<= 1 linum) (<= linum (len lines))
                (natp charpos)
                (<= charpos (len (nth-line (+ -1 linum) lines))))
           (points-in-bounds-p
            (shift-points-insert points linum charpos
                                 (- (len (split-lf payload)) 1)
                                 (len (last-seg (split-lf payload))))
            (insert-into-lines lines linum charpos payload))))

;; The pinned start point (1, 0, :right-inserting) never moves on insert.
(defthm start-point-fixed-by-shift-point-insert
  (implies (and (pointp p)
                (equal (pt-linum p) 1)
                (equal (pt-charpos p) 0)
                (eq (pt-kind p) :right-inserting)
                (natp linum) (<= 1 linum)
                (natp charpos))
           (equal (shift-point-insert p linum charpos ol oc) p)))

;; The last line of the buffer after an insert.
(defthm last-line-of-insert-into-lines
  (implies (and (line-listp lines)
                (natp linum) (<= 1 linum) (<= linum (len lines))
                (natp charpos)
                (<= charpos (len (nth-line (+ -1 linum) lines))))
           (equal (last-line (insert-into-lines lines linum charpos payload))
                  (if (< linum (len lines))
                      (last-line lines)
                      (if (consp (cdr (split-lf payload)))
                          (append (last-seg (split-lf payload))
                                  (k-drop charpos (nth-line (+ -1 linum) lines)))
                          (append (k-take charpos (nth-line (+ -1 linum) lines))
                                  (car (split-lf payload))
                                  (k-drop charpos (nth-line (+ -1 linum) lines))))))))

;; The end point (last line, end of last line, :left-inserting) tracks the end
;; of the buffer across any insert.
(defthm end-point-fields-after-insert
  (implies (and (line-listp lines)
                (pointp p)
                (equal (pt-linum p) (len lines))
                (equal (pt-charpos p) (len (last-line lines)))
                (eq (pt-kind p) :left-inserting)
                (natp linum) (<= 1 linum) (<= linum (len lines))
                (natp charpos)
                (<= charpos (len (nth-line (+ -1 linum) lines))))
           (and (equal (pt-linum
                        (shift-point-insert p linum charpos
                                            (- (len (split-lf payload)) 1)
                                            (len (last-seg (split-lf payload)))))
                       (len (insert-into-lines lines linum charpos payload)))
                (equal (pt-charpos
                        (shift-point-insert p linum charpos
                                            (- (len (split-lf payload)) 1)
                                            (len (last-seg (split-lf payload)))))
                       (len (last-line
                             (insert-into-lines lines linum charpos payload)))))))

;; Ordering between start/end and any in-bounds point is a consequence of
;; bounds + the pinned start/end fields, so preserving bounds preserves the
;; production point<= loop.
(defthm points-bounded-by-when-in-bounds
  (implies (and (points-listp points)
                (points-in-bounds-p points lines)
                (equal (pt-linum sp) 1)
                (equal (pt-charpos sp) 0)
                (equal (pt-linum ep) (len lines))
                (equal (pt-charpos ep) (len (last-line lines))))
           (points-bounded-by sp ep points)))

;; buffer-model's pt-id-of-find-point restated at the car level (pt-id opens
;; to car in goals, so the pt-id-phrased rule cannot fire there).
(defthm car-of-find-point
  (implies (find-point id points)
           (equal (car (find-point id points)) id)))

(defthm pointp-of-find-point
  (implies (and (points-listp points)
                (find-point id points))
           (pointp (find-point id points))))

(defthm point-in-bounds-of-find-point
  (implies (and (points-in-bounds-p points lines)
                (find-point id points))
           (point-in-bounds-p (find-point id points) lines)))

(defthm shift-point-insert-not-nil
  (implies (pointp p)
           (shift-point-insert p linum charpos ol oc))
  :rule-classes :type-prescription)

(defthm shift-point-delete-not-nil
  (implies (pointp p)
           (shift-point-delete p linum charpos k oc))
  :rule-classes :type-prescription)

(defthm line-listp-of-insert-into-lines
  (implies (and (line-listp lines)
                (natp linum) (<= 1 linum) (<= linum (len lines))
                (payloadp payload))
           (line-listp (insert-into-lines lines linum charpos payload))))

;; From here on the point accessors and mk-pt stay closed in proofs, so all
;; field reasoning goes through the rules above/below instead of raw cadr
;; forms (against which no field-level rule can fire).
(defthm pt-id-of-mk-pt
  (equal (pt-id (mk-pt id linum charpos kind)) id))

(defthm pt-linum-of-mk-pt
  (equal (pt-linum (mk-pt id linum charpos kind)) linum))

(defthm pt-charpos-of-mk-pt
  (equal (pt-charpos (mk-pt id linum charpos kind)) charpos))

(defthm pt-kind-of-mk-pt
  (equal (pt-kind (mk-pt id linum charpos kind)) kind))

(defthm pointp-of-mk-pt
  (equal (pointp (mk-pt id linum charpos kind))
         (and (natp id) (natp linum) (natp charpos) (kindp kind))))

(local (in-theory (disable pt-id pt-linum pt-charpos pt-kind mk-pt)))

;;; The first wf-preservation theorem (VK-2 obligation 1, insert half):
;;; editing a well-formed buffer at a valid location with a codepoint payload
;;; yields a well-formed buffer.
(defthm wf-buffer-of-k-insert
  (implies (and (wf-buffer b)
                (edit-locp b linum charpos)
                (payloadp payload))
           (wf-buffer (k-insert b linum charpos payload)))
  :hints (("Goal"
           :do-not-induct t
           :in-theory (disable shift-point-insert insert-into-lines
                               last-line point-in-bounds-p pt-<=)
           :use ((:instance points-bounded-by-when-in-bounds
                            (points (shift-points-insert
                                     (buf-points b) linum charpos
                                     (+ -1 (len (split-lf payload)))
                                     (len (last-seg (split-lf payload)))))
                            (lines (insert-into-lines
                                    (buf-lines b) linum charpos payload))
                            (sp (find-point 0 (buf-points b)))
                            (ep (shift-point-insert
                                 (find-point 1 (buf-points b)) linum charpos
                                 (+ -1 (len (split-lf payload)))
                                 (len (last-seg (split-lf payload))))))))))

;;; ===========================================================================
;;; wf-preservation, delete side (VK-2 obligation 1b)
;;; ===========================================================================

(defthm car-of-k-drop
  (equal (car (k-drop n l))
         (nth-line n l)))

(defthm consp-of-k-drop
  (implies (and (natp n) (< n (len l)))
           (consp (k-drop n l))))

(defthm payloadp-when-linep
  (implies (linep l)
           (payloadp l)))

(defthm payloadp-of-append
  (implies (and (payloadp a) (payloadp b))
           (payloadp (append a b))))

;; Keep mv-nth closed so the k-delete-lines characterization rules (phrased
;; with mv-nth) can fire; explicit tuples still compute via this rule.
(defthm mv-nth-of-cons
  (equal (mv-nth n (cons a b))
         (if (zp n) a (mv-nth (- n 1) b)))
  :hints (("Goal" :in-theory (enable mv-nth))))

(local (in-theory (disable mv-nth)))

;; k-delete-lines result characterization: nmerges/end-offset shape and types.
(defthm natp-of-kdl-nmerges
  (natp (mv-nth 2 (k-delete-lines ls charpos n)))
  :rule-classes (:rewrite :type-prescription))

(defthm natp-of-kdl-oc
  (implies (and (natp n) (natp charpos)
                (<= charpos (len (car ls))))
           (natp (mv-nth 3 (k-delete-lines ls charpos n))))
  :rule-classes (:rewrite :type-prescription))

(defthm kdl-nmerges-bound
  (implies (consp ls)
           (< (mv-nth 2 (k-delete-lines ls charpos n)) (len ls)))
  :rule-classes (:rewrite :linear))

(defthm len-of-kdl-lines
  (equal (len (mv-nth 0 (k-delete-lines ls charpos n)))
         (- (len ls) (mv-nth 2 (k-delete-lines ls charpos n)))))

(defthm consp-of-kdl-lines
  (implies (consp ls)
           (consp (mv-nth 0 (k-delete-lines ls charpos n)))))

(defthm line-listp-of-kdl-lines
  (implies (and (line-listp ls) (natp charpos) (natp n))
           (line-listp (mv-nth 0 (k-delete-lines ls charpos n)))))

(defthm payloadp-of-kdl-deleted
  (implies (line-listp ls)
           (payloadp (mv-nth 1 (k-delete-lines ls charpos n)))))

;; Everything after the merged head line is the untouched tail of LS.
(defthm cdr-of-kdl-lines
  (implies (true-listp ls)
           (equal (cdr (mv-nth 0 (k-delete-lines ls charpos n)))
                  (k-drop (+ 1 (mv-nth 2 (k-delete-lines ls charpos n))) ls))))

(defthm nth-line-of-kdl-lines-past
  (implies (and (natp i) (< 0 i) (consp ls) (true-listp ls))
           (equal (nth-line i (mv-nth 0 (k-delete-lines ls charpos n)))
                  (nth-line (+ i (mv-nth 2 (k-delete-lines ls charpos n))) ls))))

;; Length of the merged head line: same-line deletes shorten the target by OC;
;; merging deletes keep CHARPOS chars and the tail of touched line J past OC.
(defthm len-of-car-of-kdl-lines
  (implies (and (line-listp ls) (consp ls)
                (natp charpos) (<= charpos (len (car ls)))
                (natp n))
           (equal (len (car (mv-nth 0 (k-delete-lines ls charpos n))))
                  (if (equal (mv-nth 2 (k-delete-lines ls charpos n)) 0)
                      (- (len (car ls))
                         (mv-nth 3 (k-delete-lines ls charpos n)))
                      (+ charpos
                         (- (len (nth-line (mv-nth 2 (k-delete-lines ls charpos n)) ls))
                            (mv-nth 3 (k-delete-lines ls charpos n))))))))

(defthm kdl-oc-bound-same-line
  (implies (and (line-listp ls) (consp ls)
                (natp charpos) (<= charpos (len (car ls)))
                (natp n)
                (equal (mv-nth 2 (k-delete-lines ls charpos n)) 0))
           (<= (mv-nth 3 (k-delete-lines ls charpos n))
               (- (len (car ls)) charpos)))
  :rule-classes (:rewrite :linear))

(defthm kdl-oc-bound-multi
  (implies (and (line-listp ls) (consp ls)
                (natp charpos) (<= charpos (len (car ls)))
                (natp n)
                (not (equal (mv-nth 2 (k-delete-lines ls charpos n)) 0)))
           (<= (mv-nth 3 (k-delete-lines ls charpos n))
               (len (nth-line (mv-nth 2 (k-delete-lines ls charpos n)) ls))))
  :rule-classes (:rewrite :linear))

;; A pointp is exactly the list of its fields (needed because case-4 delete
;; relocation rebuilds a point at its own coordinates).
(defthm pointp-reconstruction
  (implies (pointp p)
           (equal (mk-pt (pt-id p) (pt-linum p) (pt-charpos p) (pt-kind p))
                  p))
  :hints (("Goal" :in-theory (enable mk-pt pt-id pt-linum pt-charpos pt-kind))))

;; Any single in-bounds point stays in bounds after the delete relocation with
;; the merge count and end offset k-delete derives from the buffer.
(defthm point-in-bounds-of-shift-point-delete
  (implies (and (line-listp lines)
                (pointp p)
                (point-in-bounds-p p lines)
                (natp linum) (<= 1 linum) (<= linum (len lines))
                (natp charpos)
                (<= charpos (len (nth-line (+ -1 linum) lines)))
                (natp n))
           (point-in-bounds-p
            (shift-point-delete
             p linum charpos
             (mv-nth 2 (k-delete-lines (k-drop (+ -1 linum) lines) charpos n))
             (mv-nth 3 (k-delete-lines (k-drop (+ -1 linum) lines) charpos n)))
            (append (k-take (+ -1 linum) lines)
                    (mv-nth 0 (k-delete-lines (k-drop (+ -1 linum) lines)
                                              charpos n)))))
  :hints (("Goal" :do-not-induct t
           :use ((:instance kdl-oc-bound-multi
                            (ls (k-drop (+ -1 linum) lines)))
                 (:instance kdl-oc-bound-same-line
                            (ls (k-drop (+ -1 linum) lines)))))))

(defthm points-in-bounds-of-shift-points-delete
  (implies (and (line-listp lines)
                (points-listp points)
                (points-in-bounds-p points lines)
                (natp linum) (<= 1 linum) (<= linum (len lines))
                (natp charpos)
                (<= charpos (len (nth-line (+ -1 linum) lines)))
                (natp n))
           (points-in-bounds-p
            (shift-points-delete
             points linum charpos
             (mv-nth 2 (k-delete-lines (k-drop (+ -1 linum) lines) charpos n))
             (mv-nth 3 (k-delete-lines (k-drop (+ -1 linum) lines) charpos n)))
            (append (k-take (+ -1 linum) lines)
                    (mv-nth 0 (k-delete-lines (k-drop (+ -1 linum) lines)
                                              charpos n)))))
  :hints (("Goal" :in-theory (disable shift-point-delete))))

;; The pinned start point (1, 0) never moves on delete (kind-independent).
(defthm start-point-fixed-by-shift-point-delete
  (implies (and (pointp p)
                (equal (pt-linum p) 1)
                (equal (pt-charpos p) 0)
                (natp linum) (<= 1 linum)
                (natp charpos) (natp k) (natp oc))
           (equal (shift-point-delete p linum charpos k oc) p))
  :hints (("Goal" :use ((:instance pointp-reconstruction)))))

;; Helper for the end-point theorem, phrased WITHOUT (natp linum): the prover
;; drops that literal from the reached-the-last-line subgoal (equality
;; generation types it away and the fresh clause cannot rederive it), so the
;; rule that closes that subgoal must not need it. For non-integer linum the
;; hypotheses are contradictory (nmerges is a natural but would equal
;; (len lines) - linum), whence the :cases hint.
(local
 (defthm len-of-car-of-kdl-lines-at-buffer-end
   (implies (and (line-listp lines)
                 (<= 1 linum) (< linum (len lines))
                 (natp charpos)
                 (<= charpos (len (nth-line (+ -1 linum) lines)))
                 (natp n)
                 (equal (mv-nth 2 (k-delete-lines (k-drop (+ -1 linum) lines)
                                                  charpos n))
                        (+ (- linum) (len lines))))
            (equal (len (car (mv-nth 0 (k-delete-lines (k-drop (+ -1 linum) lines)
                                                       charpos n))))
                   (+ charpos
                      (len (nth-line (+ -1 (len lines)) lines))
                      (- (mv-nth 3 (k-delete-lines (k-drop (+ -1 linum) lines)
                                                   charpos n))))))
   :hints (("Goal" :cases ((integerp linum))))))

(local
 (defthm kdl-lines-consp-at-buffer-end
   (implies (and (<= 1 linum) (< linum (len lines))
                 (equal (mv-nth 2 (k-delete-lines (k-drop (+ -1 linum) lines)
                                                  charpos n))
                        (+ (- linum) (len lines))))
            (consp (mv-nth 0 (k-delete-lines (k-drop (+ -1 linum) lines)
                                             charpos n))))
   :hints (("Goal" :cases ((integerp linum))))))

;; The end point tracks the end of the buffer across any delete.
(defthm end-point-fields-after-delete
  (implies (and (line-listp lines)
                (pointp p)
                (equal (pt-linum p) (len lines))
                (equal (pt-charpos p) (len (last-line lines)))
                (natp linum) (<= 1 linum) (<= linum (len lines))
                (natp charpos)
                (<= charpos (len (nth-line (+ -1 linum) lines)))
                (natp n))
           (and (equal (pt-linum
                        (shift-point-delete
                         p linum charpos
                         (mv-nth 2 (k-delete-lines (k-drop (+ -1 linum) lines)
                                                   charpos n))
                         (mv-nth 3 (k-delete-lines (k-drop (+ -1 linum) lines)
                                                   charpos n))))
                       (len (append (k-take (+ -1 linum) lines)
                                    (mv-nth 0 (k-delete-lines
                                               (k-drop (+ -1 linum) lines)
                                               charpos n)))))
                (equal (pt-charpos
                        (shift-point-delete
                         p linum charpos
                         (mv-nth 2 (k-delete-lines (k-drop (+ -1 linum) lines)
                                                   charpos n))
                         (mv-nth 3 (k-delete-lines (k-drop (+ -1 linum) lines)
                                                   charpos n))))
                       (len (last-line
                             (append (k-take (+ -1 linum) lines)
                                     (mv-nth 0 (k-delete-lines
                                                (k-drop (+ -1 linum) lines)
                                                charpos n))))))))
  :hints (("Goal" :do-not-induct t
           :do-not '(fertilize generalize eliminate-destructors)
           :in-theory (disable natp-of-kdl-oc kdl-oc-bound-same-line
                               kdl-oc-bound-multi)
           :use ((:instance kdl-oc-bound-multi
                            (ls (k-drop (+ -1 linum) lines)))
                 (:instance kdl-oc-bound-same-line
                            (ls (k-drop (+ -1 linum) lines)))
                 (:instance natp-of-kdl-oc
                            (ls (k-drop (+ -1 linum) lines)))))))

;;; The second wf-preservation theorem (VK-2 obligation 1, delete half).
(defthm wf-buffer-of-k-delete
  (implies (and (wf-buffer b)
                (edit-locp b linum charpos)
                (natp n))
           (wf-buffer (mv-nth 0 (k-delete b linum charpos n))))
  :hints (("Goal"
           :do-not-induct t
           :in-theory (disable shift-point-delete last-line
                               point-in-bounds-p pt-<=)
           :use ((:instance points-bounded-by-when-in-bounds
                            (points (shift-points-delete
                                     (buf-points b) linum charpos
                                     (mv-nth 2 (k-delete-lines
                                                (k-drop (+ -1 linum) (buf-lines b))
                                                charpos n))
                                     (mv-nth 3 (k-delete-lines
                                                (k-drop (+ -1 linum) (buf-lines b))
                                                charpos n))))
                            (lines (append (k-take (+ -1 linum) (buf-lines b))
                                           (mv-nth 0 (k-delete-lines
                                                      (k-drop (+ -1 linum)
                                                              (buf-lines b))
                                                      charpos n))))
                            (sp (find-point 0 (buf-points b)))
                            (ep (shift-point-delete
                                 (find-point 1 (buf-points b)) linum charpos
                                 (mv-nth 2 (k-delete-lines
                                            (k-drop (+ -1 linum) (buf-lines b))
                                            charpos n))
                                 (mv-nth 3 (k-delete-lines
                                            (k-drop (+ -1 linum) (buf-lines b))
                                            charpos n)))))))))

;;; ===========================================================================
;;; Inverse law (VK-2 obligation 2): deleting exactly what was inserted
;;; restores content AND every point
;;; ===========================================================================

(defthm k-drop-of-k-take-same
  (equal (k-drop n (k-take n l)) nil))

(defthm k-drop-of-append-le
  (implies (and (natp n) (<= n (len a)) (true-listp a))
           (equal (k-drop n (append a b))
                  (append (k-drop n a) b))))

(defthm consp-of-make-inserted-rest
  (consp (make-inserted-rest segs suffix)))

(defthm car-of-append
  (equal (car (append a b))
         (if (consp a) (car a) (car b))))

(defthm cdr-of-append
  (equal (cdr (append a b))
         (if (consp a) (append (cdr a) b) (cdr b))))

(defthm car-of-make-inserted-rest
  (equal (car (make-inserted-rest segs suffix))
         (if (atom (cdr segs))
             (append (car segs) suffix)
             (car segs))))

(defthm cdr-of-make-inserted-rest
  (equal (cdr (make-inserted-rest segs suffix))
         (if (atom (cdr segs))
             nil
             (make-inserted-rest (cdr segs) suffix))))

;; Openers: the two k-delete-lines branches as explicit rewrite rules on cons
;; terms (the automatic opening heuristics balk at the shapes the inverse-law
;; induction produces).
(defthm k-delete-lines-opener-fit
  (implies (and (integerp n) (< 0 n)
                (<= n (- (len a) charpos)))
           (equal (k-delete-lines (cons a b) charpos n)
                  (list (cons (append (k-take charpos a)
                                      (k-drop (+ charpos n) a))
                              b)
                        (k-take n (k-drop charpos a))
                        0 n)))
  :hints (("Goal" :expand ((k-delete-lines (cons a b) charpos n)))))

(defthm k-delete-lines-opener-merge
  (implies (and (integerp n) (< 0 n)
                (< (- (len a) charpos) n)
                (consp b))
           (equal (k-delete-lines (cons a b) charpos n)
                  (list (mv-nth 0 (k-delete-lines
                                   (cons (append (k-take charpos a) (car b))
                                         (cdr b))
                                   charpos
                                   (- n (+ (- (len a) charpos) 1))))
                        (append (k-drop charpos a)
                                (cons 10 (mv-nth 1 (k-delete-lines
                                                    (cons (append (k-take charpos a) (car b))
                                                          (cdr b))
                                                    charpos
                                                    (- n (+ (- (len a) charpos) 1))))))
                        (+ 1 (mv-nth 2 (k-delete-lines
                                        (cons (append (k-take charpos a) (car b))
                                              (cdr b))
                                        charpos
                                        (- n (+ (- (len a) charpos) 1)))))
                        (mv-nth 3 (k-delete-lines
                                   (cons (append (k-take charpos a) (car b))
                                         (cdr b))
                                   charpos
                                   (- n (+ (- (len a) charpos) 1)))))))
  :hints (("Goal" :expand ((k-delete-lines (cons a b) charpos n)))))

;; Deleting (len (join-lf segs)) codepoints at the start of the inserted
;; region merges it back into a single prefix++suffix line, returns exactly
;; the joined payload, and reports the very merge count and end offset that
;; k-insert used to relocate points. Core version: the delete arguments are
;; the len terms themselves so the induction hypothesis picks them up.
(local
 (defthm k-delete-lines-of-inserted-region-core
   (implies (and (linep prefix) (line-listp segs) (consp segs)
                 (linep suffix) (true-listp rest))
            (equal (k-delete-lines
                    (append (make-inserted-lines prefix segs suffix) rest)
                    (len prefix)
                    (len (join-lf segs)))
                   (list (cons (append prefix suffix) rest)
                         (join-lf segs)
                         (+ -1 (len segs))
                         (len (last-seg segs)))))
   :hints (("Goal" :induct (make-inserted-rest segs suffix)
            :do-not '(fertilize))
           ("Subgoal *1/2''"
            :expand ((k-delete-lines
                      (cons (append prefix (car segs))
                            (append (make-inserted-rest (cdr segs) suffix) rest))
                      (len prefix)
                      (+ 1 (len (car segs)) (len (join-lf (cdr segs))))))))))

;; Applicable form: fires when the delete happens at CHARPOS = |prefix| for
;; N = |join(segs)| codepoints, as at the k-insert/k-delete composition site.
(defthm k-delete-lines-of-inserted-region
  (implies (and (linep prefix) (line-listp segs) (consp segs)
                (linep suffix) (true-listp rest)
                (equal charpos (len prefix))
                (equal n (len (join-lf segs))))
           (equal (k-delete-lines
                   (append (make-inserted-lines prefix segs suffix) rest)
                   charpos n)
                  (list (cons (append prefix suffix) rest)
                        (join-lf segs)
                        (+ -1 (len segs))
                        (len (last-seg segs)))))
  :hints (("Goal" :use ((:instance k-delete-lines-of-inserted-region-core))
           :in-theory (disable k-delete-lines-of-inserted-region-core
                               k-delete-lines))))

(defthm k-take-of-k-take-same
  (equal (k-take n (k-take n l))
         (k-take n l)))

;; A buffer decomposes around any line: take, the line itself, drop the rest.
(defthm append-take-nth-drop
  (implies (and (natp j) (< j (len l)) (true-listp l))
           (equal (append (k-take j l)
                          (cons (nth-line j l) (k-drop (+ 1 j) l)))
                  l)))

;; Same fact in the 1-based shape that arises at the k-insert/k-delete
;; composition site ((+ 1 (+ -1 linum)) does not syntactically match linum).
(defthm append-take-nth-drop-1-based
  (implies (and (natp linum) (<= 1 linum) (<= linum (len l))
                (true-listp l))
           (equal (append (k-take (+ -1 linum) l)
                          (cons (nth-line (+ -1 linum) l) (k-drop linum l)))
                  l))
  :hints (("Goal" :use ((:instance append-take-nth-drop (j (+ -1 linum))))
           :in-theory (disable append-take-nth-drop))))

;; Per-point round trip: the delete relocation with the SAME merge count and
;; end offset undoes the insert relocation, for BOTH kinds -- the intermediate
;; position is kind-dependent (see the two lemmas below), the round trip is
;; not.
(defthm shift-point-delete-of-shift-point-insert
  (implies (and (pointp p) (natp linum) (<= 1 linum)
                (natp charpos) (natp ol) (natp oc))
           (equal (shift-point-delete
                   (shift-point-insert p linum charpos ol oc)
                   linum charpos ol oc)
                  p))
  :hints (("Goal" :do-not-induct t
           :use ((:instance pointp-reconstruction)))))

;; The kind-conditional boundary semantics, stated precisely: a
;; :left-inserting point AT the edit position lands at the end of the
;; inserted text ...
(defthm shift-point-insert-left-inserting-at-position
  (implies (and (pointp p) (eq (pt-kind p) :left-inserting)
                (equal (pt-linum p) linum)
                (equal (pt-charpos p) charpos)
                (natp charpos) (natp ol) (natp oc))
           (and (equal (pt-linum (shift-point-insert p linum charpos ol oc))
                       (+ (pt-linum p) ol))
                (equal (pt-charpos (shift-point-insert p linum charpos ol oc))
                       (if (equal ol 0) (+ charpos oc) oc)))))

;; ... while a :right-inserting point AT the edit position does not move.
(defthm shift-point-insert-right-inserting-at-position
  (implies (and (pointp p) (eq (pt-kind p) :right-inserting)
                (equal (pt-linum p) linum)
                (equal (pt-charpos p) charpos)
                (natp charpos))
           (equal (shift-point-insert p linum charpos ol oc) p)))

(defthm shift-points-delete-of-shift-points-insert
  (implies (and (points-listp points) (natp linum) (<= 1 linum)
                (natp charpos) (natp ol) (natp oc))
           (equal (shift-points-delete
                   (shift-points-insert points linum charpos ol oc)
                   linum charpos ol oc)
                  points))
  :hints (("Goal" :in-theory (disable shift-point-insert shift-point-delete))))

;;; The inverse law (VK-2 obligation 2): deleting exactly the inserted
;;; codepoints at the insertion location restores the lines AND every point
;;; exactly (per-kind semantics baked into the per-point round trip above),
;;; returns the payload as the deleted text, and bumps the tick twice.
(defthm k-delete-of-k-insert
  (implies (and (wf-buffer b)
                (edit-locp b linum charpos)
                (payloadp payload))
           (and (equal (mv-nth 0 (k-delete (k-insert b linum charpos payload)
                                           linum charpos (len payload)))
                       (list (buf-lines b)
                             (buf-points b)
                             (+ 2 (buf-tick b))))
                (equal (mv-nth 1 (k-delete (k-insert b linum charpos payload)
                                           linum charpos (len payload)))
                       payload)))
  :hints (("Goal" :do-not-induct t
           :in-theory (disable shift-point-insert shift-point-delete
                               make-inserted-lines make-inserted-rest))))

;;; ===========================================================================
;;; Marker order preservation (VK-2 obligation 4)
;;; ===========================================================================

;; Insert preserves STRICT order strictly. (Weak order on coincident points is
;; deliberately not preserved: at the exact insertion position a
;; :left-inserting point moves past a coincident :right-inserting one -- that
;; is production's boundary semantics, proven above, not an order bug.)
(defthm shift-point-insert-preserves-strict-order
  (implies (and (pointp p) (pointp q)
                (natp linum) (<= 1 linum)
                (natp charpos) (natp ol) (natp oc)
                (pt-<= p q)
                (not (pt-<= q p)))
           (and (pt-<= (shift-point-insert p linum charpos ol oc)
                       (shift-point-insert q linum charpos ol oc))
                (not (pt-<= (shift-point-insert q linum charpos ol oc)
                            (shift-point-insert p linum charpos ol oc)))))
  :hints (("Goal" :do-not-induct t)))

;; Delete relocation is kind-independent and monotone, so it preserves weak
;; order outright (strict order may collapse to equality when both points sat
;; inside the deleted region -- they land on the deletion start together).
(defthm shift-point-delete-preserves-order
  (implies (and (pointp p) (pointp q)
                (natp linum) (<= 1 linum)
                (natp charpos) (natp k) (natp oc)
                (pt-<= p q))
           (pt-<= (shift-point-delete p linum charpos k oc)
                  (shift-point-delete q linum charpos k oc)))
  :hints (("Goal" :do-not-induct t)))

;;; ===========================================================================
;;; Offset algebra (VK-2 obligation 5): compute-edit-offset semantics
;;; ===========================================================================

(defthm nth-of-append
  (implies (natp n)
           (equal (nth n (append a b))
                  (if (< n (len a))
                      (nth n a)
                      (nth (- n (len a)) b)))))

(defthm nth-of-k-take
  (implies (and (natp n) (natp m) (< n m))
           (equal (nth n (k-take m l))
                  (nth n l))))

(defthm nth-of-k-drop
  (implies (and (natp n) (natp m))
           (equal (nth n (k-drop m l))
                  (nth (+ n m) l))))

;; Shifting a recorded 1-based position across an untracked INSERT keeps it
;; pointing at the same character of the flattened content. (A position AT the
;; insert point shifts past the payload, exactly compute-edit-offset's <=.)
(defthm k-shift-position-insert-tracks-content
  (implies (and (true-listp flat)
                (natp src) (<= 1 src) (<= src (+ 1 (len flat)))
                (natp dest) (<= 1 dest) (<= dest (len flat))
                (true-listp payload))
           (equal (nth (+ -1 (k-shift-position-insert dest src (len payload)))
                       (append (k-take (+ -1 src) flat)
                               payload
                               (k-drop (+ -1 src) flat)))
                  (nth (+ -1 dest) flat)))
  :hints (("Goal" :do-not-induct t)))

;; Shifting a recorded 1-based position across an untracked DELETE keeps it
;; pointing at the same character, for positions strictly past the deleted
;; region (positions inside it clamp to the deletion start; their character
;; no longer exists).
(defthm k-shift-position-delete-tracks-content
  (implies (and (true-listp flat)
                (natp src) (<= 1 src) (natp n)
                (natp dest) (<= (+ src n) dest) (<= dest (len flat)))
           (equal (nth (+ -1 (k-shift-position-delete dest src n))
                       (append (k-take (+ -1 src) flat)
                               (k-drop (+ -1 src n) flat)))
                  (nth (+ -1 dest) flat)))
  :hints (("Goal" :do-not-induct t)))

;;; ===========================================================================
;;; Position <-> point round trips (position-at-point algebra)
;;; ===========================================================================

(defthm len-of-cdr
  (implies (consp l)
           (equal (len (cdr l)) (+ -1 (len l)))))

(local (defun posind (lines linum)
         (if (and (consp lines) (< 1 linum))
             (posind (cdr lines) (- linum 1))
             (list lines linum))))

(defthm nth-line-unroll
  (implies (and (natp n) (< 0 n) (consp l))
           (equal (nth-line n l)
                  (nth-line (+ -1 n) (cdr l)))))

(defthm k-point-at-position-of-k-position
  (implies (and (line-listp lines) (consp lines)
                (natp linum) (<= 1 linum) (<= linum (len lines))
                (natp charpos)
                (<= charpos (len (nth-line (+ -1 linum) lines))))
           (and (equal (mv-nth 0 (k-point-at-position
                                  lines (k-position lines linum charpos)))
                       linum)
                (equal (mv-nth 1 (k-point-at-position
                                  lines (k-position lines linum charpos)))
                       charpos)))
  :hints (("Goal" :induct (posind lines linum))))

;;; ===========================================================================
;;; Content laws (VK-2 obligation 3): k-insert is splice, k-delete is excision
;;; on the flattened codepoint content
;;; ===========================================================================

(defthm append-nil-right
  (implies (true-listp a)
           (equal (append a nil) a)))

(defthm true-listp-of-k-flatten
  (implies (line-listp ls)
           (true-listp (k-flatten ls))))

(local (defun list-count-ind (a m)
         (if (consp a)
             (list-count-ind (cdr a) (- m 1))
             (list a m))))

(defthm k-take-of-append-ge
  (implies (and (true-listp a) (natp m) (<= (len a) m))
           (equal (k-take m (append a b))
                  (append a (k-take (- m (len a)) b))))
  :hints (("Goal" :induct (list-count-ind a m))))

(defthm k-drop-of-append-ge
  (implies (and (true-listp a) (natp m) (<= (len a) m))
           (equal (k-drop m (append a b))
                  (k-drop (- m (len a)) b)))
  :hints (("Goal" :induct (list-count-ind a m))))

;; Flatten of the inserted region: prefix, the joined payload, and the suffix
;; line merged with whatever follows.
(defthm k-flatten-of-make-inserted-rest-append
  (implies (and (line-listp segs) (consp segs) (linep suffix))
           (equal (k-flatten (append (make-inserted-rest segs suffix) after))
                  (append (join-lf segs)
                          (k-flatten (cons suffix after))))))

(defthm k-flatten-of-make-inserted-lines-append
  (implies (and (linep prefix) (line-listp segs) (consp segs) (linep suffix))
           (equal (k-flatten (append (make-inserted-lines prefix segs suffix) after))
                  (append prefix
                          (join-lf segs)
                          (k-flatten (cons suffix after))))))

;; The k-delete-lines content facts, by induction on its own recursion, each
;; split into the fits / runs-off-the-end cases (the min-phrased combined
;; forms explode the prover): how much was deleted, that the deleted text is
;; a contiguous chunk of the flattened tail, and that the remaining lines
;; flatten to the excision.
(defthm len-of-kdl-deleted-fits
  (implies (and (line-listp ls) (consp ls)
                (natp charpos) (<= charpos (len (car ls)))
                (natp n)
                (<= n (- (len (k-flatten ls)) charpos)))
           (equal (len (mv-nth 1 (k-delete-lines ls charpos n))) n))
  :hints (("Goal" :induct (k-delete-lines ls charpos n))))

(defthm len-of-kdl-deleted-overrun
  (implies (and (line-listp ls) (consp ls)
                (natp charpos) (<= charpos (len (car ls)))
                (natp n)
                (> n (- (len (k-flatten ls)) charpos)))
           (equal (len (mv-nth 1 (k-delete-lines ls charpos n)))
                  (- (len (k-flatten ls)) charpos)))
  :hints (("Goal" :induct (k-delete-lines ls charpos n))))

(defthm kdl-deleted-is-flat-chunk-fits
  (implies (and (line-listp ls) (consp ls)
                (natp charpos) (<= charpos (len (car ls)))
                (natp n)
                (<= n (- (len (k-flatten ls)) charpos)))
           (equal (mv-nth 1 (k-delete-lines ls charpos n))
                  (k-take n (k-drop charpos (k-flatten ls)))))
  :hints (("Goal" :induct (k-delete-lines ls charpos n))))

(defthm kdl-deleted-is-flat-chunk-overrun
  (implies (and (line-listp ls) (consp ls)
                (natp charpos) (<= charpos (len (car ls)))
                (natp n)
                (> n (- (len (k-flatten ls)) charpos)))
           (equal (mv-nth 1 (k-delete-lines ls charpos n))
                  (k-drop charpos (k-flatten ls))))
  :hints (("Goal" :induct (k-delete-lines ls charpos n))))

(defthm k-flatten-of-kdl-lines-fits
  (implies (and (line-listp ls) (consp ls)
                (natp charpos) (<= charpos (len (car ls)))
                (natp n)
                (<= n (- (len (k-flatten ls)) charpos)))
           (equal (k-flatten (mv-nth 0 (k-delete-lines ls charpos n)))
                  (append (k-take charpos (k-flatten ls))
                          (k-drop (+ charpos n) (k-flatten ls)))))
  :hints (("Goal" :induct (k-delete-lines ls charpos n))))

(defthm k-flatten-of-kdl-lines-overrun
  (implies (and (line-listp ls) (consp ls)
                (natp charpos) (<= charpos (len (car ls)))
                (natp n)
                (> n (- (len (k-flatten ls)) charpos)))
           (equal (k-flatten (mv-nth 0 (k-delete-lines ls charpos n)))
                  (k-take charpos (k-flatten ls))))
  :hints (("Goal" :induct (k-delete-lines ls charpos n))))

;; Flatten decomposition machinery for lifting the tail-level facts to the
;; whole buffer.
(defthm k-flatten-of-append-flatten-n
  (implies (and (true-listp a) (consp b))
           (equal (k-flatten (append a b))
                  (append (k-flatten-n a (len a)) (k-flatten b)))))

(defthm k-flatten-n-of-k-take
  (implies (natp j)
           (equal (k-flatten-n (k-take j l) j)
                  (k-flatten-n l j)))
  :hints (("Goal" :induct (list-count-ind l j))))

(defthm len-of-k-flatten-n
  (equal (len (k-flatten-n lines j))
         (flat-len-before lines j)))

;; The whole flattened buffer splits at any line boundary. Used via :use
;; (j is free in the right-hand side, so this cannot be a rewrite rule).
(defthm fl-decomp
  (implies (and (natp j) (< j (len lines)) (line-listp lines))
           (equal (k-flatten lines)
                  (append (k-flatten-n lines j)
                          (k-flatten (k-drop j lines)))))
  :rule-classes nil
  :hints (("Goal" :induct (list-count-ind lines j))))

;; One step of the flattened tail: the target line, then (when more lines
;; follow) the separating 10 and the rest.
(defthm k-flatten-of-k-drop-cons
  (implies (and (natp j) (< j (len lines)) (true-listp lines))
           (equal (k-flatten (k-drop j lines))
                  (if (consp (k-drop (+ 1 j) lines))
                      (append (nth-line j lines)
                              (cons 10 (k-flatten (k-drop (+ 1 j) lines))))
                      (nth-line j lines))))
  :hints (("Goal" :induct (list-count-ind lines j))))

;; Flatten-n of the inserted region (the form arising when more lines follow
;; the insertion).
(defthm k-flatten-n-of-make-inserted-rest
  (implies (and (line-listp segs) (consp segs) (linep suffix))
           (equal (k-flatten-n (make-inserted-rest segs suffix) (len segs))
                  (append (join-lf segs) suffix (list 10)))))

(defthm k-flatten-n-of-make-inserted-lines
  (implies (and (linep prefix) (line-listp segs) (consp segs) (linep suffix))
           (equal (k-flatten-n (make-inserted-lines prefix segs suffix) (len segs))
                  (append prefix (join-lf segs) suffix (list 10)))))

(defthm cdr-of-k-drop
  (implies (and (natp n) (true-listp l))
           (equal (cdr (k-drop n l))
                  (k-drop (+ 1 n) l))))

(defthm k-take-ge-len
  (implies (and (true-listp x) (integerp m) (<= (len x) m))
           (equal (k-take m x) x)))

;;; The insert content law (VK-2 obligation 3a): the flattened content of the
;;; edited buffer is exactly the payload spliced into the flattened content at
;;; the (1-based) edit position.
(defthm k-flatten-of-k-insert
  (implies (and (wf-buffer b)
                (edit-locp b linum charpos)
                (payloadp payload))
           (equal (k-flatten (buf-lines (k-insert b linum charpos payload)))
                  (append (k-take (+ -1 (k-position (buf-lines b) linum charpos))
                                  (k-flatten (buf-lines b)))
                          payload
                          (k-drop (+ -1 (k-position (buf-lines b) linum charpos))
                                  (k-flatten (buf-lines b))))))
  :hints (("Goal" :do-not-induct t
           :in-theory (disable make-inserted-lines make-inserted-rest
                               shift-point-insert)
           :use ((:instance fl-decomp (j (+ -1 linum)) (lines (buf-lines b)))))))

;;; The delete content law (VK-2 obligation 3b): the flattened content of the
;;; edited buffer is the excision of min(n, available) codepoints at the edit
;;; position, and the returned deleted text is exactly that excised chunk.
(defthm content-of-k-delete
  (implies (and (wf-buffer b)
                (edit-locp b linum charpos)
                (natp n))
           (and (equal (k-flatten (buf-lines (mv-nth 0 (k-delete b linum charpos n))))
                       (append (k-take (+ -1 (k-position (buf-lines b) linum charpos))
                                       (k-flatten (buf-lines b)))
                               (k-drop (+ (+ -1 (k-position (buf-lines b) linum charpos))
                                          (min n (- (len (k-flatten (buf-lines b)))
                                                    (+ -1 (k-position (buf-lines b) linum charpos)))))
                                       (k-flatten (buf-lines b)))))
                (equal (mv-nth 1 (k-delete b linum charpos n))
                       (k-take (min n (- (len (k-flatten (buf-lines b)))
                                         (+ -1 (k-position (buf-lines b) linum charpos))))
                               (k-drop (+ -1 (k-position (buf-lines b) linum charpos))
                                       (k-flatten (buf-lines b)))))))
  :hints (("Goal" :do-not-induct t
           :in-theory (disable shift-point-delete)
           :use ((:instance fl-decomp (j (+ -1 linum)) (lines (buf-lines b))))
           :cases ((<= n (- (len (k-flatten (k-drop (+ -1 linum) (buf-lines b))))
                            charpos))))))
