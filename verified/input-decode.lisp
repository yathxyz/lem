;;;; verified/input-decode.lisp -- Terminal input decode kernel (SPEC-VK VK-7).
;;;;
;;;; One source of truth (SPEC-VK Constraint 2): this same file is certified by
;;;; ACL2 (scripts/run-proofs.sh) AND loaded verbatim into the Lem SBCL image
;;;; through verified/shim.lisp.  Production frontends/ncurses/input.lisp
;;;; DELEGATES its pure decision logic to the functions in this book:
;;;;   * `k-decode-csi-key' / `k-decode-csi-modifier' -- the CSI key decoder
;;;;     (production `decode-csi-key' is now a thin struct-conversion wrapper),
;;;;   * `k-paste-init' / `k-paste-step' / `k-paste-payload' -- the bracketed-
;;;;     paste accumulator state machine (production `collect-bracketed-paste'
;;;;     is now a getch driver looping over `k-paste-step').
;;;;
;;;; MODEL.  Terminal input is a list of ITEMS:
;;;;   * a nat 0..255            -- a raw byte from the terminal,
;;;;   * (:code n), n a nat      -- a curses keypad-translated keycode >= 256
;;;;                                (e.g. KEY_RESIZE = 410 = #o632),
;;;;   * :timeout                -- a read timeout (production getch -1).
;;;; `k-decode' maps an item list to a list of EVENTS, transcribing production
;;;; `get-event''s case analysis (input.lisp): key events are records
;;;; (:key sym shift meta ctrl) with SYM a codepoint list (ACL2 strings are
;;;; 8-bit and are NEVER used here); paste events carry codepoint-list payloads.
;;;; End of the item list is modeled as a timeout (a real terminal read would
;;;; block / time out there).
;;;;
;;;; BOUNDARY WITH THE SHELL (documented per VK-7; also in verified/README.md):
;;;;   * UTF-8 ASSEMBLY: production does multibyte assembly in `get-key',
;;;;     strictly BELOW the CSI layer (CSI sequences are pure ASCII; `get-key'
;;;;     is only reached for non-CSI input).  The byte-COUNTING (`utf8-bytes')
;;;;     is transcribed here as `k-utf8-len' so the list model can consume
;;;;     multibyte characters, but VALIDITY checking and decoding of the byte
;;;;     group to a character stay in the shell (babel/SBCL -- trust base).
;;;;     The model emits (:char bytes) / (:meta-char bytes) with the raw group.
;;;;   * KEYCODE TABLES: the terminfo keycode->key table (lem-ncurses/key) is
;;;;     shell data; the model emits (:curses-key n) / (:meta-code n).
;;;;   * SGR MOUSE: read-sgr-mouse-event's DECODING is out of VK-7 scope; the
;;;;     model transcribes only its stream CONSUMPTION (digits/';' consumed up
;;;;     to and including the first other item, or timeout) and emits (:mouse).
;;;;   * The impure weave of `get-event' (getch, wtimeout, tagbody) remains in
;;;;     the shell; this book is its pure functional mirror, pinned by the
;;;;     differential PBT suite (tests/pbt/input-decode-conformance.lisp) and
;;;;     the lem-ncurses/tests suites which now run against the kernel-backed
;;;;     production entry points.
;;;;
;;;; PRODUCTION SEMANTICS MIRRORED (frontends/ncurses/input.lisp):
;;;;   * `decode-csi-modifier': mod parameter 1 (or absent) = no modifiers;
;;;;     encoding is 1 + bitmask Shift=1, Alt(Meta)=2, Ctrl=4.
;;;;   * `decode-csi-key': the CSI 1;<mod> letter family (A-F/H, P-S) and the
;;;;     CSI <n>;<mod>~ tilde family; parameter 200 is bracketed paste, never a
;;;;     key; unknown finals/parameters yield NIL (shell falls back to Escape).
;;;;   * `collect-bracketed-paste': terminator ESC[201~ matched incrementally;
;;;;     a failed partial match flushes the matched terminator prefix into the
;;;;     payload verbatim and reconsiders the current byte against ESC; a
;;;;     translated keycode (:code n) is dropped (it can never be a payload
;;;;     byte); a timeout ends the paste with the payload collected so far
;;;;     (a pending partial terminator match is NOT flushed on timeout --
;;;;     production behavior, pinned by the ncurses bracketed-paste suite).
;;;;     The flush uses an explicit prefix table (`term-prefix') rather than
;;;;     production's index loop over the terminator array -- same bytes by
;;;;     construction (the table IS the loop's unrolling).
;;;;   * `read-csi': digits accumulate a parameter, ';' pushes it (possibly
;;;;     absent = NIL), a final byte in 0x40-0x7E dispatches, anything else --
;;;;     timeout, keycode, stray byte -- falls back to Escape.
;;;;   * `get-event': -1 retries, C-] (29) is :abort, KEY_RESIZE is :resize,
;;;;     ESC starts the timeout-disambiguated escape/meta/CSI branching.
;;;;
;;;; EXEC PATH (functions the production shell or the PBT suite actually
;;;; calls): everything except the `local' lemma scaffolding.  These use only
;;;; CL homonyms plus the shim whitelist (natp, len, true-listp) -- no shim
;;;; whitelist growth for VK-7.
;;;;
;;;; DEVIATIONS from a byte-perfect transcription (all recorded in README):
;;;;   * Non-item garbage in the input list is dropped, one element at a time
;;;;     (production cannot receive it; ACL2 totality demands SOME behavior).
;;;;   * A (:code n) or :timeout inside a multibyte UTF-8 continuation window
;;;;     ends the byte group early ((:char ...) with the bytes read so far);
;;;;     production stores getch's raw return into an (unsigned-byte 8) vector
;;;;     on this path -- a latent type error, not transcribable behavior.
;;;;   * `k-decode' processes the whole item list; production reads one event
;;;;     per `get-event' call.  Sequencing is otherwise identical.

(in-package "ACL2")

;; Proof-only lemma library (local: nothing from it is exec-reachable).
(local (include-book "std/lists/top" :dir :system))

;;; ===========================================================================
;;; Input items
;;; ===========================================================================

(defun bytep (x)
  (and (natp x) (<= x 255)))

(defun codep (x)
  (and (consp x)
       (eq (car x) :code)
       (consp (cdr x))
       (natp (cadr x))
       (null (cddr x))))

(defun itemp (x)
  (or (bytep x)
      (eq x :timeout)
      (codep x)))

(defun item-listp (l)
  (if (atom l)
      (null l)
      (and (itemp (car l))
           (item-listp (cdr l)))))

(defun byte-listp (l)
  (if (atom l)
      (null l)
      (and (bytep (car l))
           (byte-listp (cdr l)))))

;; A codepoint list (naturals; key syms are ASCII in practice but any nat is wf).
(defun cpsp (l)
  (if (atom l)
      (null l)
      (and (natp (car l))
           (cpsp (cdr l)))))

(defun boolp (x)
  (or (eq x t) (eq x nil)))

;;; ===========================================================================
;;; Small lookup helpers (own definitions: no ACL2-only built-ins on exec path)
;;; ===========================================================================

;; eql-keyed alist lookup (keys are nats here).
(defun alist-get (key alist)
  (cond ((atom alist) nil)
        ((eql key (caar alist)) (cdar alist))
        (t (alist-get key (cdr alist)))))

;; equal-keyed alist lookup (keys are codepoint lists).
(defun alist-get-equal (key alist)
  (cond ((atom alist) nil)
        ((equal key (caar alist)) (cdar alist))
        (t (alist-get-equal key (cdr alist)))))

(defun mem-equal (x l)
  (cond ((atom l) nil)
        ((equal x (car l)) l)
        (t (mem-equal x (cdr l)))))

;;; ===========================================================================
;;; Key events
;;; ===========================================================================

(defun mk-key-ev (sym shift meta ctrl)
  (list :key sym shift meta ctrl))

(defun key-ev-sym (ev) (cadr ev))
(defun key-ev-shift (ev) (caddr ev))
(defun key-ev-meta (ev) (cadddr ev))
(defun key-ev-ctrl (ev) (car (cddddr ev)))

(defun key-evp (ev)
  (and (true-listp ev)
       (eql (len ev) 5)
       (eq (car ev) :key)
       (cpsp (key-ev-sym ev))
       (boolp (key-ev-shift ev))
       (boolp (key-ev-meta ev))
       (boolp (key-ev-ctrl ev))))

;; "Escape" = (69 115 99 97 112 101); the fail-closed fallback key.
(defun esc-key-ev ()
  (mk-key-ev '(69 115 99 97 112 101) nil nil nil))

(defun eventp (ev)
  (and (consp ev)
       (true-listp ev)
       (cond ((eq (car ev) :key) (key-evp ev))
             ((eq (car ev) :paste)
              (and (eql (len ev) 2) (byte-listp (cadr ev))))
             ((eq (car ev) :char)
              (and (eql (len ev) 2) (consp (cadr ev)) (byte-listp (cadr ev))))
             ((eq (car ev) :meta-char)
              (and (eql (len ev) 2) (consp (cadr ev)) (byte-listp (cadr ev))))
             ((eq (car ev) :meta-code)
              (and (eql (len ev) 2) (natp (cadr ev))))
             ((eq (car ev) :curses-key)
              (and (eql (len ev) 2) (natp (cadr ev))))
             ((eq (car ev) :resize) (null (cdr ev)))
             ((eq (car ev) :abort) (null (cdr ev)))
             ((eq (car ev) :mouse) (null (cdr ev)))
             (t nil))))

(defun event-listp (l)
  (if (atom l)
      (null l)
      (and (eventp (car l))
           (event-listp (cdr l)))))

;;; ===========================================================================
;;; CSI key tables (production +csi-final-syms+ / +csi-tilde-syms+, with chars
;;; as codepoints and syms as codepoint lists)
;;; ===========================================================================

(defun csi-final-syms ()
  ;; final byte -> sym:  A "Up"  B "Down"  C "Right"  D "Left"  E "Begin"
  ;;                     F "End" H "Home"  P "F1" Q "F2" R "F3" S "F4"
  '((65 . (85 112))
    (66 . (68 111 119 110))
    (67 . (82 105 103 104 116))
    (68 . (76 101 102 116))
    (69 . (66 101 103 105 110))
    (70 . (69 110 100))
    (72 . (72 111 109 101))
    (80 . (70 49))
    (81 . (70 50))
    (82 . (70 51))
    (83 . (70 52))))

(defun csi-tilde-syms ()
  ;; first parameter -> sym: 1/7 "Home" 2 "Insert" 3 "Delete" 4/8 "End"
  ;;                         5 "PageUp" 6 "PageDown" 11-15,17-21,23,24 F1-F12
  '((1 . (72 111 109 101))
    (2 . (73 110 115 101 114 116))
    (3 . (68 101 108 101 116 101))
    (4 . (69 110 100))
    (5 . (80 97 103 101 85 112))
    (6 . (80 97 103 101 68 111 119 110))
    (7 . (72 111 109 101))
    (8 . (69 110 100))
    (11 . (70 49))
    (12 . (70 50))
    (13 . (70 51))
    (14 . (70 52))
    (15 . (70 53))
    (17 . (70 54))
    (18 . (70 55))
    (19 . (70 56))
    (20 . (70 57))
    (21 . (70 49 48))
    (23 . (70 49 49))
    (24 . (70 49 50))))

;;; ===========================================================================
;;; CSI modifier / key decoding (production decode-csi-modifier/decode-csi-key)
;;; ===========================================================================

;; xterm CSI modifier parameter -> (mv shift meta ctrl).
;; MOD = 1 (or NIL) means none; encoding is 1 + bitmask Shift=1 Alt=2 Ctrl=4.
(defun k-decode-csi-modifier (mod)
  (let ((bits (max 0 (- (or mod 1) 1))))
    (mv (logbitp 0 bits)
        (logbitp 1 bits)
        (logbitp 2 bits))))

(defun k-make-modified-key (sym mod)
  (mv-let (shift meta ctrl)
          (k-decode-csi-modifier mod)
    (mk-key-ev sym shift meta ctrl)))

;; CSI sequence -> key event, or NIL when the parser does not recognise it
;; (bracketed paste parameter 200, unknown final byte / parameter).  FINAL is
;; the final byte as a codepoint; PARAMS is the list of numeric parameters
;; (NIL for an empty field).
(defun k-decode-csi-key (final params)
  (if (eql final 126)
      (let ((n (or (nth 0 params) 1)))
        (if (eql n 200)
            nil
            (let ((sym (alist-get n (csi-tilde-syms))))
              (if sym
                  (k-make-modified-key sym (nth 1 params))
                  nil))))
      (let ((sym (alist-get final (csi-final-syms))))
        (if sym
            (k-make-modified-key sym (nth 1 params))
            nil))))

;;; ===========================================================================
;;; UTF-8 byte-group consumption (production utf8-bytes / get-key's assembly
;;; loop; validity + decoding stay in the shell -- see header)
;;; ===========================================================================

(defun k-utf8-len (b)
  (cond ((<= b 127) 1)
        ((and (<= 194 b) (<= b 223)) 2)
        ((and (<= 224 b) (<= b 239)) 3)
        ((and (<= 240 b) (<= b 244)) 4)
        (t 1)))

;; Take up to N leading BYTE items; a :timeout / (:code n) / list end stops the
;; group early.  (mv taken rest).
(defun k-take-bytes (n items)
  (if (or (not (integerp n))
          (<= n 0)
          (atom items)
          (not (bytep (car items))))
      (mv nil items)
      (mv-let (taken rest)
              (k-take-bytes (- n 1) (cdr items))
        (mv (cons (car items) taken) rest))))

;; Consume one UTF-8 byte group starting at (car items), which must be a byte.
;; (mv bytes rest); bytes is always non-empty.
(defun k-read-utf8 (items)
  (mv-let (taken rest)
          (k-take-bytes (- (k-utf8-len (car items)) 1) (cdr items))
    (mv (cons (car items) taken) rest)))

;;; ===========================================================================
;;; Bracketed paste (production collect-bracketed-paste as a step machine)
;;; ===========================================================================

;; The ESC[201~ terminator.
(defun k-paste-term ()
  (list 27 91 50 48 49 126))

;; The first M bytes of the terminator (the unrolling of production's flush
;; loop over +bracketed-paste-end+).
(defun term-prefix (m)
  (cond ((eql m 0) nil)
        ((eql m 1) '(27))
        ((eql m 2) '(27 91))
        ((eql m 3) '(27 91 50))
        ((eql m 4) '(27 91 50 48))
        ((eql m 5) '(27 91 50 48 49))
        (t '(27 91 50 48 49 126))))

;; Accumulator state: (match reversed-payload).
(defun k-paste-init ()
  (list 0 nil))

(defun paste-stp (st)
  (and (true-listp st)
       (eql (len st) 2)
       (natp (car st))
       (<= (car st) 6)
       (byte-listp (cadr st))))

;; One accumulator step: (mv state done-p).  Transcribes production's loop
;; body: timeout stops; a keycode (:code n) is dropped; a byte matching the
;; next terminator byte advances the match (completing it stops); otherwise a
;; partial match is flushed into the payload and the byte is reconsidered
;; against the terminator's first byte (ESC).
(defun k-paste-step (st item)
  (let ((match (car st))
        (rpay (cadr st)))
    (cond ((eq item :timeout)
           (mv st t))
          ((not (bytep item))
           (mv st nil))
          ((eql item (nth match (k-paste-term)))
           (mv (list (+ match 1) rpay)
               (eql (+ match 1) 6)))
          (t
           (let ((flushed (revappend (term-prefix match) rpay)))
             (if (eql item 27)
                 (mv (list 1 flushed) nil)
                 (mv (list 0 (cons item flushed)) nil)))))))

(defun k-paste-payload (st)
  (revappend (cadr st) nil))

(defun k-collect-paste-loop (items st)
  (if (atom items)
      (mv (k-paste-payload st) items)
      (mv-let (st2 done)
              (k-paste-step st (car items))
        (if done
            (mv (k-paste-payload st2) (cdr items))
            (k-collect-paste-loop (cdr items) st2)))))

;; Collect a bracketed-paste payload from ITEMS (after the ESC[200~
;; introducer).  (mv payload rest).
(defun k-collect-paste (items)
  (k-collect-paste-loop items (k-paste-init)))

;;; ===========================================================================
;;; SGR mouse stream consumption (decoding is shell -- see header)
;;; ===========================================================================

;; Transcribes read-sgr-mouse-event's consumption: digits and ';' are
;; consumed; the first other item (M/m final, malformed byte, keycode) is
;; consumed and stops; a timeout stops.  (mv event rest).
(defun k-read-mouse (items)
  (cond ((atom items) (mv (list :mouse) items))
        ((eq (car items) :timeout) (mv (list :mouse) (cdr items)))
        ((and (bytep (car items))
              (or (and (<= 48 (car items)) (<= (car items) 57))
                  (eql (car items) 59)))
         (k-read-mouse (cdr items)))
        (t (mv (list :mouse) (cdr items)))))

;;; ===========================================================================
;;; CSI accumulation + dispatch (production read-csi / dispatch-csi)
;;; ===========================================================================

;; Dispatch a fully-read CSI sequence: parameter 200 with final '~' starts a
;; bracketed paste; otherwise decode a key or fall back to Escape.
(defun k-dispatch-csi (final params rest)
  (if (and (eql final 126)
           (eql (nth 0 params) 200))
      (mv-let (payload rest2)
              (k-collect-paste rest)
        (mv (list :paste payload) rest2))
      (mv (or (k-decode-csi-key final params) (esc-key-ev))
          rest)))

;; Accumulate CSI parameters until a final byte in 0x40-0x7E dispatches.
;; CUR is the parameter being accumulated (NIL when its field is empty so
;; far); RPARAMS the already-pushed parameters, reversed.  Any unexpected
;; item -- timeout, keycode, stray byte -- aborts to Escape, consuming it.
(defun k-read-csi (items cur rparams)
  (cond ((atom items) (mv (esc-key-ev) items))
        ((eq (car items) :timeout) (mv (esc-key-ev) (cdr items)))
        ((not (bytep (car items))) (mv (esc-key-ev) (cdr items)))
        ((and (<= 48 (car items)) (<= (car items) 57))
         (k-read-csi (cdr items)
                     (+ (* 10 (or cur 0)) (- (car items) 48))
                     rparams))
        ((eql (car items) 59)
         (k-read-csi (cdr items) nil (cons cur rparams)))
        ((and (<= 64 (car items)) (<= (car items) 126))
         (k-dispatch-csi (car items)
                         (revappend rparams (list cur))
                         (cdr items)))
        (t (mv (esc-key-ev) (cdr items)))))

;;; ===========================================================================
;;; ESC branching (production get-event's escape branch)
;;; ===========================================================================

;; After ESC [ (the CSI introducer): '<' starts an SGR mouse report; a timeout
;; falls back to Escape; anything else is CSI parameter accumulation.
(defun k-decode-csi-intro (items)
  (cond ((atom items) (mv (esc-key-ev) items))
        ((eq (car items) :timeout) (mv (esc-key-ev) (cdr items)))
        ((eql (car items) 60) (k-read-mouse (cdr items)))
        (t (k-read-csi items nil nil))))

;; After ESC: a timeout means the Escape key itself; '[' introduces CSI; a
;; keycode becomes a meta'd keycode; any byte becomes a meta'd character
;; (production wraps get-key's result with :meta t).
(defun k-decode-esc (items)
  (cond ((atom items) (mv (esc-key-ev) items))
        ((eq (car items) :timeout) (mv (esc-key-ev) (cdr items)))
        ((codep (car items)) (mv (list :meta-code (cadr (car items)))
                                 (cdr items)))
        ((eql (car items) 91) (k-decode-csi-intro (cdr items)))
        ((bytep (car items))
         (mv-let (bytes rest)
                 (k-read-utf8 items)
           (mv (list :meta-char bytes) rest)))
        (t (mv nil (cdr items)))))

;;; ===========================================================================
;;; Top-level decode (production get-event's case analysis)
;;; ===========================================================================

;; Decode one event from a non-empty item list: (mv event-or-nil rest).
;; NIL event = the item produced nothing (top-level timeout, garbage).
;; KEY_RESIZE = #o632 = 410; C-] = 29 (:abort); ESC = 27.
(defun k-decode-1 (items)
  (let ((it (car items)))
    (cond ((eq it :timeout) (mv nil (cdr items)))
          ((codep it)
           (if (eql (cadr it) 410)
               (mv (list :resize) (cdr items))
               (mv (list :curses-key (cadr it)) (cdr items))))
          ((not (bytep it)) (mv nil (cdr items)))
          ((eql it 29) (mv (list :abort) (cdr items)))
          ((eql it 27) (k-decode-esc (cdr items)))
          (t (mv-let (bytes rest)
                     (k-read-utf8 items)
               (mv (list :char bytes) rest))))))

;;; --- progress lemmas (also the VK-7 obligation-2 statements) --------------

(defthm k-take-bytes-rest-len
  (<= (len (mv-nth 1 (k-take-bytes n items))) (len items))
  :rule-classes (:rewrite :linear))

(defthm k-read-utf8-rest-len
  (implies (consp items)
           (< (len (mv-nth 1 (k-read-utf8 items))) (len items)))
  :rule-classes (:rewrite :linear))

(defthm k-collect-paste-loop-rest-len
  (<= (len (mv-nth 1 (k-collect-paste-loop items st))) (len items))
  :rule-classes (:rewrite :linear))

(defthm k-collect-paste-rest-len
  (<= (len (mv-nth 1 (k-collect-paste items))) (len items))
  :rule-classes (:rewrite :linear))

(defthm k-read-mouse-rest-len
  (<= (len (mv-nth 1 (k-read-mouse items))) (len items))
  :rule-classes (:rewrite :linear))

(defthm k-dispatch-csi-rest-len
  (<= (len (mv-nth 1 (k-dispatch-csi final params rest))) (len rest))
  :rule-classes (:rewrite :linear))

(defthm k-read-csi-rest-len
  (<= (len (mv-nth 1 (k-read-csi items cur rparams))) (len items))
  :rule-classes (:rewrite :linear))

(defthm k-decode-csi-intro-rest-len
  (<= (len (mv-nth 1 (k-decode-csi-intro items))) (len items))
  :rule-classes (:rewrite :linear))

(defthm k-decode-esc-rest-len
  (<= (len (mv-nth 1 (k-decode-esc items))) (len items))
  :rule-classes (:rewrite :linear))

;; Obligation 2 (progress): decoding one event always consumes at least one
;; input item -- the decoder can never loop without making progress.
(defthm k-decode-1-progress
  (implies (consp items)
           (< (len (mv-nth 1 (k-decode-1 items))) (len items)))
  :rule-classes (:rewrite :linear))

;; The whole-stream decoder.  Total: admission IS the termination proof, via
;; k-decode-1-progress ("fail closed to Escape" as a theorem: every input,
;; including garbage, decodes without hanging or signalling).
(defun k-decode (items)
  (declare (xargs :measure (len items)))
  (if (atom items)
      nil
      (mv-let (ev rest)
              (k-decode-1 items)
        (if ev
            (cons ev (k-decode rest))
            (k-decode rest)))))

;;; ===========================================================================
;;; Obligation 2 (no-overconsumption): the remainder returned at every level
;;; is a genuine suffix of the input -- the decoder never reads past the items
;;; it was given, and never reorders or refetches.
;;; ===========================================================================

(defun k-suffixp (x y)
  (if (equal x y)
      t
      (and (consp y)
           (k-suffixp x (cdr y)))))

(defthm k-suffixp-reflexive
  (k-suffixp x x))

(defthm k-suffixp-of-cdr-weaken
  (implies (and (consp y) (k-suffixp x (cdr y)))
           (k-suffixp x y)))

(defthm k-take-bytes-rest-suffixp
  (k-suffixp (mv-nth 1 (k-take-bytes n items)) items))

(defthm k-read-utf8-rest-suffixp
  (implies (consp items)
           (k-suffixp (mv-nth 1 (k-read-utf8 items)) items)))

(defthm k-collect-paste-loop-rest-suffixp
  (k-suffixp (mv-nth 1 (k-collect-paste-loop items st)) items))

(defthm k-collect-paste-rest-suffixp
  (k-suffixp (mv-nth 1 (k-collect-paste items)) items))

(defthm k-read-mouse-rest-suffixp
  (k-suffixp (mv-nth 1 (k-read-mouse items)) items))

(defthm k-dispatch-csi-rest-suffixp
  (k-suffixp (mv-nth 1 (k-dispatch-csi final params rest)) rest))

(defthm k-read-csi-rest-suffixp
  (k-suffixp (mv-nth 1 (k-read-csi items cur rparams)) items))

(defthm k-decode-csi-intro-rest-suffixp
  (k-suffixp (mv-nth 1 (k-decode-csi-intro items)) items))

(defthm k-decode-esc-rest-suffixp
  (k-suffixp (mv-nth 1 (k-decode-esc items)) items))

(defthm k-decode-1-no-overconsumption
  (implies (true-listp items)
           (k-suffixp (mv-nth 1 (k-decode-1 items)) items)))

;; Corollary: an item list can never produce more events than it has items.
(defthm k-decode-event-count
  (<= (len (k-decode items)) (len items))
  :rule-classes (:rewrite :linear))

;;; ===========================================================================
;;; Obligation 1 (totality + well-formedness): for EVERY input list -- bytes,
;;; keycodes, timeouts, even non-item garbage -- the decoder terminates
;;; (admission above) and yields a well-formed event list.  Nothing signals.
;;; ===========================================================================

(local (defthm byte-listp-of-append
         (implies (and (byte-listp x) (byte-listp y))
                  (byte-listp (append x y)))))

(local (defthm byte-listp-of-rev
         (implies (byte-listp x)
                  (byte-listp (rev x)))))

(defthm byte-listp-of-revappend
  (implies (and (byte-listp x) (byte-listp y))
           (byte-listp (revappend x y))))

(defthm byte-listp-of-term-prefix
  (byte-listp (term-prefix m)))

(defthm paste-stp-of-k-paste-init
  (paste-stp (k-paste-init)))

(defthm paste-stp-of-k-paste-step
  (implies (paste-stp st)
           (paste-stp (mv-nth 0 (k-paste-step st item)))))

(defthm byte-listp-of-k-paste-payload
  (implies (paste-stp st)
           (byte-listp (k-paste-payload st))))

(defthm byte-listp-of-k-collect-paste-loop
  (implies (paste-stp st)
           (byte-listp (mv-nth 0 (k-collect-paste-loop items st)))))

;; Paste payloads are always codepoint (byte) lists, whatever arrives.
(defthm byte-listp-of-k-collect-paste
  (byte-listp (mv-nth 0 (k-collect-paste items))))

(defthm cpsp-of-alist-get-final-syms
  (cpsp (alist-get key (csi-final-syms))))

(defthm cpsp-of-alist-get-tilde-syms
  (cpsp (alist-get key (csi-tilde-syms))))

(defthm boolp-of-logbitp
  (boolp (logbitp i j)))

(defthm key-evp-of-k-make-modified-key
  (implies (cpsp sym)
           (key-evp (k-make-modified-key sym mod))))

;; The CSI key decoder yields NIL or a well-formed key event, for any input.
(defthm key-evp-of-k-decode-csi-key
  (implies (k-decode-csi-key final params)
           (key-evp (k-decode-csi-key final params))))

(defthm key-evp-of-esc-key-ev
  (key-evp (esc-key-ev)))

(defthm eventp-when-key-evp
  (implies (key-evp ev)
           (eventp ev)))

(defthm eventp-of-meta-code-event
  (implies (natp n)
           (eventp (list :meta-code n))))

(defthm eventp-of-curses-key-event
  (implies (natp n)
           (eventp (list :curses-key n))))

(defthm eventp-of-resize-event
  (eventp (list :resize)))

(defthm eventp-of-abort-event
  (eventp (list :abort)))

(defthm eventp-of-mouse-event
  (eventp (list :mouse)))

(defthm byte-listp-of-k-take-bytes
  (byte-listp (mv-nth 0 (k-take-bytes n items))))

(defthm eventp-of-k-read-utf8-char
  (implies (bytep (car items))
           (eventp (list :char (mv-nth 0 (k-read-utf8 items))))))

(defthm eventp-of-k-read-utf8-meta-char
  (implies (bytep (car items))
           (eventp (list :meta-char (mv-nth 0 (k-read-utf8 items))))))

(defthm eventp-of-k-read-mouse
  (implies (mv-nth 0 (k-read-mouse items))
           (eventp (mv-nth 0 (k-read-mouse items)))))

(defthm eventp-of-paste-event
  (implies (byte-listp payload)
           (eventp (list :paste payload))))

(defthm eventp-of-k-dispatch-csi
  (implies (mv-nth 0 (k-dispatch-csi final params rest))
           (eventp (mv-nth 0 (k-dispatch-csi final params rest))))
  :hints (("Goal" :in-theory (disable eventp k-decode-csi-key
                                      k-collect-paste-loop
                                      key-evp-of-k-decode-csi-key)
           :use (key-evp-of-k-decode-csi-key))))

(defthm eventp-of-k-read-csi
  (implies (mv-nth 0 (k-read-csi items cur rparams))
           (eventp (mv-nth 0 (k-read-csi items cur rparams))))
  :hints (("Goal" :in-theory (disable eventp k-dispatch-csi))))

(defthm eventp-of-k-decode-csi-intro
  (implies (mv-nth 0 (k-decode-csi-intro items))
           (eventp (mv-nth 0 (k-decode-csi-intro items))))
  :hints (("Goal" :in-theory (disable eventp k-read-csi k-read-mouse))))

(defthm eventp-of-k-decode-esc
  (implies (mv-nth 0 (k-decode-esc items))
           (eventp (mv-nth 0 (k-decode-esc items))))
  :hints (("Goal" :in-theory (disable eventp k-decode-csi-intro k-read-utf8))))

(defthm eventp-of-k-decode-1
  (implies (mv-nth 0 (k-decode-1 items))
           (eventp (mv-nth 0 (k-decode-1 items))))
  :hints (("Goal" :in-theory (disable eventp k-decode-esc k-read-utf8))))

;; Obligation 1: any input decodes to a well-formed event list.
(defthm event-listp-of-k-decode
  (event-listp (k-decode items))
  :hints (("Goal" :induct (k-decode items)
           :in-theory (disable eventp k-decode-1))))

;;; ===========================================================================
;;; Obligation 3 (round-trip on the supported table).  k-encode-key encodes
;;; every supported key canonically (letter family for the cursor/F1-F4 keys,
;;; tilde family for the rest); decode o encode = identity is proved for the
;;; WHOLE table -- the recognizer supported-key-evp quantifies over all
;;; supported syms x all 8 modifier combinations (184 keys), via an
;;; exhaustively evaluated ground theorem, not examples.
;;; ===========================================================================

(defun letter-encode-alist ()
  ;; sym -> final byte (canonical encodings ESC [ 1 ; <mod> <final>)
  '(((85 112) . 65)                     ; Up      -> A
    ((68 111 119 110) . 66)             ; Down    -> B
    ((82 105 103 104 116) . 67)         ; Right   -> C
    ((76 101 102 116) . 68)             ; Left    -> D
    ((66 101 103 105 110) . 69)         ; Begin   -> E
    ((69 110 100) . 70)                 ; End     -> F
    ((72 111 109 101) . 72)             ; Home    -> H
    ((70 49) . 80)                      ; F1      -> P
    ((70 50) . 81)                      ; F2      -> Q
    ((70 51) . 82)                      ; F3      -> R
    ((70 52) . 83)))                    ; F4      -> S

(defun tilde-encode-alist ()
  ;; sym -> first parameter (canonical encodings ESC [ <n> ; <mod> ~)
  '(((73 110 115 101 114 116) . 2)      ; Insert
    ((68 101 108 101 116 101) . 3)      ; Delete
    ((80 97 103 101 85 112) . 5)        ; PageUp
    ((80 97 103 101 68 111 119 110) . 6) ; PageDown
    ((70 53) . 15)                      ; F5
    ((70 54) . 17)                      ; F6
    ((70 55) . 18)                      ; F7
    ((70 56) . 19)                      ; F8
    ((70 57) . 20)                      ; F9
    ((70 49 48) . 21)                   ; F10
    ((70 49 49) . 23)                   ; F11
    ((70 49 50) . 24)))                 ; F12

;; Decimal digits of a parameter (supported parameters are 1..24).
(defun nat-digits (n)
  (if (< n 10)
      (list (+ 48 n))
      (list (+ 48 (floor n 10)) (+ 48 (mod n 10)))))

(defun key-ev-mod-bits (ev)
  (+ (if (key-ev-shift ev) 1 0)
     (if (key-ev-meta ev) 2 0)
     (if (key-ev-ctrl ev) 4 0)))

;; Encode a supported key event as the item (byte) list its terminal sends.
;; The modifier parameter is always emitted (1 = no modifiers).
(defun k-encode-key (ev)
  (let* ((sym (key-ev-sym ev))
         (mod-digit (+ 49 (key-ev-mod-bits ev)))
         (final (alist-get-equal sym (letter-encode-alist))))
    (if final
        (list 27 91 49 59 mod-digit final)
        (let ((n (alist-get-equal sym (tilde-encode-alist))))
          (if n
              (append (list 27 91)
                      (append (nat-digits n)
                              (list 59 mod-digit 126)))
              nil)))))

(defun alist-keys-l (alist)
  (if (atom alist)
      nil
      (cons (caar alist) (alist-keys-l (cdr alist)))))

(defun canonical-syms ()
  (append (alist-keys-l (letter-encode-alist))
          (alist-keys-l (tilde-encode-alist))))

(defun mods-list ()
  '((nil nil nil) (t nil nil) (nil t nil) (t t nil)
    (nil nil t) (t nil t) (nil t t) (t t t)))

(defun keys-for-sym (sym mods)
  (if (atom mods)
      nil
      (cons (mk-key-ev sym (car (car mods)) (cadr (car mods)) (caddr (car mods)))
            (keys-for-sym sym (cdr mods)))))

(defun keys-for-syms (syms)
  (if (atom syms)
      nil
      (append (keys-for-sym (car syms) (mods-list))
              (keys-for-syms (cdr syms)))))

;; Every supported key: 23 syms x 8 modifier combinations.
(defun all-supported-keys ()
  (keys-for-syms (canonical-syms)))

;; The supported-table recognizer.
(defun supported-key-evp (ev)
  (if (mem-equal ev (all-supported-keys)) t nil))

(defun round-trips-p (keys)
  (if (atom keys)
      t
      (and (equal (k-decode (k-encode-key (car keys)))
                  (list (car keys)))
           (round-trips-p (cdr keys)))))

;; The exhaustive ground fact: every one of the 184 supported keys round-trips.
;; ACL2 proves this by evaluation -- the decode of each encoding is computed.
(defthm all-supported-keys-round-trip
  (round-trips-p (all-supported-keys))
  :rule-classes nil)

(local (defthm round-trips-p-member
         (implies (and (round-trips-p keys)
                       (mem-equal ev keys))
                  (equal (k-decode (k-encode-key ev))
                         (list ev)))))

;; Obligation 3: decode o encode = identity for EVERY supported key.
(defthm k-decode-of-k-encode-key
  (implies (supported-key-evp ev)
           (equal (k-decode (k-encode-key ev))
                  (list ev)))
  :hints (("Goal"
           :in-theory (disable k-decode k-encode-key mem-equal
                               (:executable-counterpart k-decode)
                               (:executable-counterpart k-encode-key))
           :use (all-supported-keys-round-trip
                 (:instance round-trips-p-member
                            (keys (all-supported-keys)))))))

;;; ===========================================================================
;;; Obligations 4 + 5 (bracketed paste).
;;;   4. Exact payload reconstruction: for ANY byte payload P that does not
;;;      contain the full ESC[201~ terminator -- including payloads with
;;;      embedded and trailing PROPER PREFIXES of it -- collecting
;;;      P ++ terminator yields exactly P.  (The restart-at-ESC flush logic is
;;;      exact for this terminator: ESC occurs only at its first position.)
;;;   5. Keycodes (:code n) inside a paste are dropped: they never corrupt
;;;      the payload and never abort the paste.
;;; ===========================================================================

(defun starts-with (pre l)
  (if (atom pre)
      t
      (and (consp l)
           (eql (car pre) (car l))
           (starts-with (cdr pre) (cdr l)))))

(defun contains-paste-term (l)
  (if (atom l)
      nil
      (or (starts-with (k-paste-term) l)
          (contains-paste-term (cdr l)))))

;;; --- local proof scaffolding ----------------------------------------------

;; The bytes accounted for by a state: payload so far ++ pending match prefix.
(local (defun paste-trace (st)
         (append (rev (cadr st)) (term-prefix (car st)))))

;; term-prefix grows one terminator byte at a time.
(local (defthm term-prefix-step
         (implies (and (natp m) (< m 5))
                  (equal (term-prefix (+ m 1))
                         (append (term-prefix m)
                                 (list (nth m (k-paste-term))))))
         :hints (("Goal" :cases ((eql m 0) (eql m 1) (eql m 2)
                                 (eql m 3) (eql m 4))))))

;; "Processing P from match state M never completes the terminator" -- the
;; step machine's own recursion structure, so inductions align with
;; k-paste-step exactly.
(local (defun clean-run-p (p m)
         (if (atom p)
             t
             (if (eql (car p) (nth m (k-paste-term)))
                 (if (eql (+ m 1) 6)
                     nil
                     (clean-run-p (cdr p) (+ m 1)))
                 (if (eql (car p) 27)
                     (clean-run-p (cdr p) 1)
                     (clean-run-p (cdr p) 0))))))

(local (defthm contains-of-append-right
         (implies (contains-paste-term y)
                  (contains-paste-term (append x y)))
         :hints (("Goal" :induct (contains-paste-term x)))))

;; Bridge: absence of the full terminator (with the pending prefix prepended)
;; implies the run never completes.
(local (defthm not-contains-implies-clean-run
         (implies (and (byte-listp p)
                       (natp m) (< m 6)
                       (not (contains-paste-term
                             (append (term-prefix m) p))))
                  (clean-run-p p m))
         :hints (("Goal" :induct (clean-run-p p m)
                  :in-theory (enable term-prefix)))))

;; Feeding exactly the terminator from any live state completes the paste with
;; the state's trace as payload (a pending partial match is flushed by the
;; terminator's own ESC, then the terminator matches from the start).
(local (defthm paste-loop-term-only
         (implies (and (paste-stp st)
                       (< (car st) 6))
                  (equal (k-collect-paste-loop '(27 91 50 48 49 126) st)
                         (mv (paste-trace st) nil)))
         :hints (("Goal" :cases ((eql (car st) 0) (eql (car st) 1)
                                 (eql (car st) 2) (eql (car st) 3)
                                 (eql (car st) 4) (eql (car st) 5))))))

(local (defun paste-ind (p st)
         (if (atom p)
             (list p st)
             (mv-let (st2 done)
                     (k-paste-step st (car p))
               (declare (ignore done))
               (paste-ind (cdr p) st2)))))

(local (defthm paste-loop-append-clean
         (implies (and (byte-listp p)
                       (paste-stp st)
                       (< (car st) 6)
                       (clean-run-p p (car st)))
                  (equal (mv-nth 0 (k-collect-paste-loop
                                    (append p (k-paste-term)) st))
                         (append (paste-trace st) p)))
         :hints (("Goal" :induct (paste-ind p st)))))

;; Obligation 4: exact payload reconstruction, embedded terminator prefixes
;; included.
(defthm paste-exact-reconstruction
  (implies (and (byte-listp p)
                (not (contains-paste-term p)))
           (equal (mv-nth 0 (k-collect-paste (append p (k-paste-term))))
                  p))
  :hints (("Goal"
           :in-theory (disable k-collect-paste-loop paste-loop-append-clean
                               not-contains-implies-clean-run)
           :use ((:instance paste-loop-append-clean (st (k-paste-init)))
                 (:instance not-contains-implies-clean-run (m 0))))))

(defun drop-code-items (l)
  (if (atom l)
      nil
      (if (codep (car l))
          (drop-code-items (cdr l))
          (cons (car l) (drop-code-items (cdr l))))))

(local (defthm paste-loop-drops-codes
         (equal (mv-nth 0 (k-collect-paste-loop (drop-code-items items) st))
                (mv-nth 0 (k-collect-paste-loop items st)))
         :hints (("Goal" :induct (k-collect-paste-loop items st)))))

;; Obligation 5: (:code n) items inside a paste are dropped -- the payload is
;; exactly the payload of the same stream with the keycodes removed (so they
;; can neither corrupt the payload nor abort the paste).
(defthm paste-drops-codes
  (equal (mv-nth 0 (k-collect-paste (drop-code-items items)))
         (mv-nth 0 (k-collect-paste items))))
