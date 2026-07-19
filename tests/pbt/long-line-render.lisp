;;;; tests/pbt/long-line-render.lisp -- OPT-1 regression pin (bench/README.md
;;;; ledger): redisplaying a single line >= ~24k chars used to CRASH the editor
;;;; with a control-stack overflow, because three verified/layout.lisp
;;;; recursions on the render path -- `k-sum' (object width), `k-firstn'
;;;; (explode halving) and `k-clip-chars' (per-char clip scan) -- recursed
;;;; non-tail with depth = line length.  They are now mbe :exec tail-recursive
;;;; accumulator twins (proved equal to the :logic recursion at ACL2 guard
;;;; verification; the shim runs the :exec branch exactly as guard-verified
;;;; ACL2 execution does).
;;;;
;;;; Two pins:
;;;;   1. A 300k-char single line renders through the FULL production path
;;;;      (redraw-buffer -> physical-line.lisp -> kernel) on the CURRENT
;;;;      window of the recording fake interface (so the cursor overlay and
;;;;      horizontal-scroll tracking are live, as in a real session), wrap on
;;;;      and off, cursor mid and end, without stack overflow -- and the
;;;;      visible rows match the certified kernel as oracle (k-wrap row
;;;;      contents for the wrap path, the scroll-window substring for the
;;;;      no-wrap path), in the screen-projection style.  This also
;;;;      empirically verifies that SBCL's compiling load gives the
;;;;      shim-loaded twins genuine tail-call elimination (a ~300k-deep
;;;;      :exec call chain must complete).
;;;;   2. An equality PBT: on random inputs the in-image kernel functions
;;;;      (running the :exec twins) equal naive test-local transcriptions of
;;;;      the :logic recursions -- guarding the twins beyond ACL2's own
;;;;      proof, cheap.

(defpackage :lem-tests/pbt/long-line-render
  (:use :cl
        :rove
        :lem-tests/pbt/harness)
  (:import-from :lem-fake-interface
                :with-recording-interface
                :recording-frame-alist
                :recording-cells-text))
(in-package :lem-tests/pbt/long-line-render)

(defparameter *line-length* 300000
  "Well past the pre-fix crash boundaries (~24k via redraw-display in the T2/T3
harnesses, 50 650 via redraw-buffer, measured at the pre-fix HEAD on the
default control stack).")

(defun ksym (name) (find-symbol name "ACL2"))

;;; ------------------------------------------------------------------
;;; Pin 1: 300k-char single-line render, kernel as oracle
;;; ------------------------------------------------------------------

(defun make-long-line (n)
  "Deterministic printable-ASCII content (width 1 per char) so screen text is
position-checkable against substrings."
  (let ((s (make-string n)))
    (dotimes (i n s)
      (setf (char s i) (code-char (+ 97 (mod i 26)))))))

(defun render-current-window (line wrap-p cursor-pos)
  "Erase the current buffer, insert LINE, park the cursor and force a full
redraw of the CURRENT window.  Returns the recorded frame rows (y-sorted) and
the window."
  (let ((buffer (lem:current-buffer))
        (window (lem:current-window)))
    (setf (lem:variable-value 'lem:line-wrap :buffer buffer) wrap-p)
    (lem:erase-buffer buffer)
    (lem:insert-string (lem:buffer-point buffer) line)
    (lem:move-to-position (lem:buffer-point buffer) cursor-pos)
    (lem-core::redraw-buffer (lem:implementation) buffer window t)
    (values (recording-frame-alist (lem:window-view window)) window)))

(defun wrap-oracle-rows (line view-width fuel)
  "Certified-kernel oracle for the wrap path: k-wrap row code lists for LINE
as one text object of per-char width 1 (the ncurses reality for ASCII)."
  (let ((codes (map 'list #'char-code line)))
    (multiple-value-bind (rows rest)
        (funcall (ksym "K-WRAP")
                 (list (funcall (ksym "K-TEXT") codes
                                (make-list (length line) :initial-element 1)
                                nil))
                 view-width fuel)
      (declare (ignore rest))
      (loop :for row :in rows
            :collect (loop :for obj :in row
                           :append (copy-list (second obj)))))))

(defun row-text-sans-marker (text wrap-char)
  "Strip the trailing wrap marker from a rendered row.  Every wrapped row
carries one -- including the LAST visible row when the logical line continues
past the window height.  Unconditional stripping is safe here because the
test line is a-z only (the marker glyph never occurs as content)."
  (if (and (plusp (length text))
           (char= (char text (1- (length text))) wrap-char))
      (subseq text 0 (1- (length text)))
      text))

(deftest long-line-render-no-overflow
  (with-recording-interface ()
    (let* ((n *line-length*)
           (line (make-long-line n))
           (wrap-char (lem:variable-value 'lem:wrap-line-character
                                          :default (lem:current-buffer))))
      ;; Wrap ON, cursor mid and end: the visible rows must match the
      ;; certified k-wrap oracle row for row (this render used to overflow in
      ;; k-sum / k-firstn: depth = line length).
      (dolist (cursor-pos (list (floor n 2) (1+ n)))
        (multiple-value-bind (rows window)
            (render-current-window line t cursor-pos)
          (let ((view-width (lem-core::window-view-width window)))
            (ok (< 3 (length rows))
                (format nil "wrap-on cursor@~d: rendered ~d rows" cursor-pos (length rows)))
            (let ((oracle (wrap-oracle-rows line view-width (length rows))))
              (ok (and (= (length oracle) (length rows))
                       (loop :for (y . cells) :in rows
                             :for expected :in oracle
                             :always
                             (string= (row-text-sans-marker
                                       (recording-cells-text cells)
                                       wrap-char)
                                      (map 'string #'code-char expected))))
                  (format nil "wrap-on cursor@~d: rows match the k-wrap oracle"
                          cursor-pos))))))
      ;; Wrap OFF, cursor mid and end: horizontal scroll follows the cursor
      ;; deep into the line, so the k-clip/k-clip-chars scan walks hundreds of
      ;; thousands of chars (the path that used to overflow after k-sum); the
      ;; single visible row must be the scroll window's exact substring.
      (dolist (cursor-pos (list (floor n 2) (1+ n)))
        (multiple-value-bind (rows window)
            (render-current-window line nil cursor-pos)
          (let* ((view-width (lem-core::window-view-width window))
                 (start (lem-core::horizontal-scroll-start window)))
            (ok (= 1 (length rows))
                (format nil "wrap-off cursor@~d: one row" cursor-pos))
            ;; The deep-scan hazard is real only if the window scrolled far in.
            (ok (> start 100000)
                (format nil "wrap-off cursor@~d: scroll-start ~d (deep scan exercised)"
                        cursor-pos start))
            (let ((text (recording-cells-text (cdr (first rows))))
                  (expected (subseq line start (min n (+ start view-width)))))
              (ok (string= expected
                           ;; The row may end in an eol-cursor cell past the
                           ;; text when the cursor is at end-of-line; compare
                           ;; the text prefix.
                           (subseq text 0 (min (length text) (length expected))))
                  (format nil "wrap-off cursor@~d: row is the scroll-window substring"
                          cursor-pos)))))))))

;;; ------------------------------------------------------------------
;;; Pin 2: exec twins = naive recursion (test-local :logic transcriptions)
;;; ------------------------------------------------------------------

(defun naive-k-sum (l)
  (if (atom l)
      0
      (+ (let ((x (car l))) (if (and (integerp x) (<= 0 x)) x 0))
         (naive-k-sum (cdr l)))))

(defun naive-k-firstn (n l)
  (if (or (not (and (integerp n) (<= 0 n))) (eql n 0) (atom l))
      nil
      (cons (car l) (naive-k-firstn (- n 1) (cdr l)))))

(defun naive-k-clip-chars (codes widths x start-x end-x)
  (if (atom codes)
      (values nil nil)
      (if (<= end-x x)
          (values nil nil)
          (let ((cw (let ((w (car widths))) (if (and (integerp w) (<= 0 w)) w 0))))
            (multiple-value-bind (sel-codes sel-widths)
                (naive-k-clip-chars (cdr codes) (cdr widths)
                                    (+ x cw) start-x end-x)
              (if (and (<= start-x x)
                       (<= (+ x cw) end-x))
                  (values (cons (car codes) sel-codes)
                          (cons (car widths) sel-widths))
                  (values sel-codes sel-widths)))))))

(defun gen-width-list ()
  "Random width list incl. junk entries (k-nat coerces junk to 0)."
  (make-generator
   :sample (lambda (rng)
             (loop :repeat (rng-below rng 60)
                   :collect (let ((r (rng-below rng 10)))
                              (cond ((< r 7) (rng-below rng 4))
                                    ((< r 8) nil)
                                    ((< r 9) -3)
                                    (t :junk)))))
   :shrink (lambda (l) (lem-tests/pbt/harness::shrink-list l (constantly nil)))))

(deftest layout-exec-twins-equal-naive-recursion
  (let ((*num-tests* 300))
    (for-all ((widths (gen-width-list))
              (n (gen-integer :min -2 :max 80))
              (start-x (gen-integer :min -5 :max 40))
              (span (gen-integer :min 0 :max 60)))
      (let ((codes (loop :for i :from 0 :below (length widths) :collect i)))
        (and (equal (funcall (ksym "K-SUM") widths)
                    (naive-k-sum widths))
             (equal (funcall (ksym "K-FIRSTN") n widths)
                    (naive-k-firstn n widths))
             (multiple-value-bind (kc kw)
                 (funcall (ksym "K-CLIP-CHARS") codes widths 0 start-x (+ start-x span))
               (multiple-value-bind (nc nw)
                   (naive-k-clip-chars codes widths 0 start-x (+ start-x span))
                 (and (equal kc nc) (equal kw nw)))))))))
