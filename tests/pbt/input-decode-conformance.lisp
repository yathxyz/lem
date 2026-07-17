;;;; tests/pbt/input-decode-conformance.lisp -- SPEC-VK VK-7 differential/PBT
;;;; acceptance for the terminal input decode kernel.
;;;;
;;;; Exercises the certified kernel (verified/input-decode.lisp, loaded through
;;;; the lem-verified-kernel system) on:
;;;;   * random item streams -- byte soup, truncated CSI sequences, interleaved
;;;;     timeouts and curses keycodes -- asserting totality (no signal), output
;;;;     well-formedness (event-listp) and progress (event count bounded by the
;;;;     item count; k-decode-1 always consumes and returns a genuine tail),
;;;;   * encode/decode round trips over randomly drawn supported keys, singly
;;;;     and concatenated,
;;;;   * bracketed-paste payload reconstruction with embedded proper prefixes
;;;;     of the ESC[201~ terminator, interleaved keycodes, and huge payloads,
;;;;   * fixed regression cases transcribed from the lem-ncurses test corpora
;;;;     (frontends/ncurses/tests/csi-decode.lisp, bracketed-paste.lisp); the
;;;;     ncurses suites themselves remain the production-integration gate,
;;;;     running against the kernel-backed production entry points.

(defpackage :lem-tests/pbt/input-decode-conformance
  (:use :cl
        :rove
        :lem-tests/pbt/harness))
(in-package :lem-tests/pbt/input-decode-conformance)

;;; ------------------------------------------------------------------
;;; Kernel access (loaded by the lem-verified-kernel system dependency)
;;; ------------------------------------------------------------------

(defun k-decode (items) (lem/kernel:k-decode items))
(defun k-decode-1 (items) (lem/kernel:k-decode-1 items))
(defun k-encode-key (key) (lem/kernel:k-encode-key key))
(defun event-listp (events) (lem/kernel:event-listp events))
(defun item-listp (items) (lem/kernel:item-listp items))

(defun k-collect-paste (items)
  "Kernel paste collection: (values payload rest)."
  (lem/kernel:k-collect-paste items))

(defparameter +terminator+ '(27 91 50 48 49 126)
  "The ESC[201~ bracketed-paste terminator as an item (byte) list.")

(defparameter +paste-intro+ '(27 91 50 48 48 126)
  "The ESC[200~ bracketed-paste introducer as an item (byte) list.")

;;; ------------------------------------------------------------------
;;; Generators
;;; ------------------------------------------------------------------

(defparameter *structure-bytes* #(27 91 126 59 60 48 49 50 53 57 65 77 109 200)
  "Bytes over-represented in random streams so CSI/paste/mouse structure forms.")

(defun gen-item ()
  "A generator of input items: bytes (structure-heavy), :timeout, (:code n)."
  (make-generator
   :sample (lambda (rng)
             (let ((r (rng-below rng 100)))
               (cond ((< r 45) (rng-below rng 256))
                     ((< r 80) (rng-element rng *structure-bytes*))
                     ((< r 90) :timeout)
                     (t (list :code (rng-range rng 256 1000))))))
   :shrink (lambda (item)
             (cond ((eql item 0) '())
                   ((integerp item) (list 0))
                   (t (list 0))))))

(defun gen-item-stream (&key (max-length 40))
  "A generator of random item lists (garbage byte soup with structure mixed in)."
  (gen-list (gen-item) :max-length max-length))

(defun gen-payload-with-prefixes ()
  "A generator of paste payloads: bytes excluding 126 (so the full terminator
can never occur) with proper prefixes of the terminator spliced in."
  (make-generator
   :sample
   (lambda (rng)
     (loop :repeat (rng-range rng 0 12)
           :nconc (if (rng-boolean rng)
                      (list (let ((b (rng-below rng 256)))
                              (if (eql b 126) 27 b)))
                      (copy-list (subseq +terminator+ 0 (rng-range rng 1 5))))))
   :shrink (lambda (payload)
             (when (consp payload) (list (butlast payload))))))

(defun gen-supported-key ()
  "A generator drawing a random key from the kernel's supported table."
  (let ((keys (coerce (lem/kernel:all-supported-keys) 'vector)))
    (make-generator
     :sample (lambda (rng) (rng-element rng keys))
     :shrink (constantly nil))))

;;; ------------------------------------------------------------------
;;; Totality / well-formedness / progress on arbitrary streams
;;; ------------------------------------------------------------------

(deftest decode-total-wf-on-random-streams
  (for-all ((items (gen-item-stream)))
    (let ((events (k-decode items)))
      (and (event-listp events)
           ;; progress: never more events than items.
           (<= (length events) (length items))))))

(deftest decode-1-progress-and-no-overconsumption
  (for-all ((items (gen-item-stream :max-length 20)))
    (or (null items)
        (multiple-value-bind (event rest) (k-decode-1 items)
          (and (or (null event) (lem/kernel:eventp event))
               ;; consumes at least one item...
               (< (length rest) (length items))
               ;; ...and returns a genuine tail of the input (never invents
               ;; or reorders items).
               (tailp rest items))))))

(deftest decode-total-on-adversarial-fixed-streams
  ;; truncated CSI, ESC at end of input, lone introducers, mixed keycodes.
  (dolist (items (list '(27)
                       '(27 91)
                       '(27 91 49)
                       '(27 91 49 59)
                       '(27 91 49 59 53)
                       '(27 91 :timeout 65)
                       '(27 :timeout)
                       '(27 (:code 410))
                       '(27 91 60)
                       '(27 91 60 48 59 49 48 59 50 48)
                       (list 27 91 50 48 48 126) ; paste intro, then nothing
                       (append +paste-intro+ '(104 105 :timeout))
                       (append +paste-intro+ '((:code 632)) +terminator+)
                       '(:timeout :timeout (:code 999) 255 0 127 128)))
    (ok (event-listp (k-decode items))
        (format nil "wf decode of ~S" items))))

;;; ------------------------------------------------------------------
;;; Encode/decode round trip over the supported table
;;; ------------------------------------------------------------------

(deftest round-trip-random-supported-keys
  (for-all ((key (gen-supported-key)))
    (equal (k-decode (k-encode-key key)) (list key))))

(deftest round-trip-concatenated-keys
  (for-all ((keys (gen-list (gen-supported-key) :min-length 1 :max-length 6)))
    (equal (k-decode (mapcan #'k-encode-key (copy-list keys)))
           keys)))

;;; ------------------------------------------------------------------
;;; Bracketed paste
;;; ------------------------------------------------------------------

(deftest paste-reconstruction-with-terminator-prefixes
  (for-all ((payload (gen-payload-with-prefixes)))
    (equal (k-collect-paste (append payload +terminator+))
           payload)))

(deftest paste-keycodes-dropped
  (for-all ((payload (gen-payload-with-prefixes))
            (code (gen-integer :min 256 :max 2000)))
    (let ((with-code (append payload
                             (list (list :code code))
                             +terminator+)))
      (equal (k-collect-paste with-code) payload))))

(deftest paste-huge-payload
  (let ((payload (loop :repeat 50000 :collect (mod (* 7 (random 256)) 256))))
    (setf payload (substitute 27 126 payload)) ; keep it terminator-free
    (ok (equal (k-collect-paste (append payload +terminator+)) payload)
        "50k-byte paste payload reconstructs exactly")))

(deftest paste-inside-full-decode
  (for-all ((payload (gen-payload-with-prefixes)))
    (let ((events (k-decode (append +paste-intro+ payload +terminator+))))
      (and (= 1 (length events))
           (equal (first events) (list :paste payload))))))

;;; ------------------------------------------------------------------
;;; Fixed regression cases from the ncurses test corpora
;;; ------------------------------------------------------------------

(defun decode-csi (final &rest params)
  "Kernel-level mirror of the csi-decode suite's DECODE helper."
  (lem/kernel:k-decode-csi-key (char-code final) params))

(defun key-parts (event)
  "The (sym shift meta ctrl) of a kernel key event, sym as a string."
  (list (map 'string #'code-char (lem/kernel:key-ev-sym event))
        (and (lem/kernel:key-ev-shift event) t)
        (and (lem/kernel:key-ev-meta event) t)
        (and (lem/kernel:key-ev-ctrl event) t)))

(deftest csi-decode-corpus
  ;; frontends/ncurses/tests/csi-decode.lisp cases at the kernel level.
  (ok (equal '("Up" nil nil t) (key-parts (decode-csi #\A 1 5))))
  (ok (equal '("Left" nil t nil) (key-parts (decode-csi #\D 1 3))))
  (ok (equal '("Right" t nil nil) (key-parts (decode-csi #\C 1 2))))
  (ok (equal '("End" nil nil t) (key-parts (decode-csi #\F 1 5))))
  (ok (equal '("F5" t nil nil) (key-parts (decode-csi #\~ 15 2))))
  (ok (equal '("PageDown" nil nil t) (key-parts (decode-csi #\~ 6 5))))
  (ok (equal '("Delete" nil nil t) (key-parts (decode-csi #\~ 3 5))))
  (ok (equal '("Begin" nil nil t) (key-parts (decode-csi #\E 1 5))))
  ;; all eight modifier combinations on Up.
  (loop :for mod :from 1 :to 8
        :for bits := (1- mod)
        :do (ok (equal (list "Up"
                             (logbitp 0 bits) (logbitp 1 bits) (logbitp 2 bits))
                       (key-parts (decode-csi #\A 1 mod)))
                (format nil "modifier ~D" mod)))
  ;; non-keys.
  (ok (null (decode-csi #\~ 200)))
  (ok (null (decode-csi #\Z 1 5)))
  (ok (null (decode-csi #\~ 99 5))))

(deftest bracketed-paste-corpus
  ;; frontends/ncurses/tests/bracketed-paste.lisp cases at the kernel level.
  (flet ((collect (items) (k-collect-paste (append items +terminator+))))
    (ok (equal (map 'list #'char-code "hello")
               (collect (map 'list #'char-code "hello"))))
    (ok (null (collect '())))
    ;; terminfo sequences are literal bytes.
    (ok (equal '(27 91 65 27 79 80) (collect '(27 91 65 27 79 80))))
    ;; keycode >= 256 dropped, surrounding bytes kept.
    (ok (equal '(104 105) (collect '(104 (:code 632) 105))))
    ;; failed partial terminator match flushed verbatim.
    (ok (equal '(97 27 91 50 48 49 98) (collect '(97 27 91 50 48 49 98))))
    ;; timeout returns the partial payload.
    (ok (equal '(120 121 122) (k-collect-paste '(120 121 122))))
    (ok (equal '(120 121 122) (k-collect-paste '(120 121 122 :timeout 99))))))
