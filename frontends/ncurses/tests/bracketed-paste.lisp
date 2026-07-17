(defpackage :lem-ncurses/tests/bracketed-paste
  (:use :cl :rove))
(in-package :lem-ncurses/tests/bracketed-paste)

;;; Unit tests for the pure bracketed-paste accumulator
;;; (lem-ncurses/input::collect-bracketed-paste). These lock the terminator
;;; matching and, crucially, that a translated keycode >= 256 can never reach
;;; the (unsigned-byte 8) accumulator (the TF-1 crash). The live keypad toggle
;;; in READ-BRACKETED-PASTE is exercised by the scripted tmux acceptance.

(defparameter +terminator+ '(27 91 50 48 49 126) ; ESC [ 2 0 1 ~
  "The ESC[201~ terminator, appended to every feed.")

(defun make-feeder (codes)
  "Return a thunk yielding each of CODES in turn, then -1 (timeout) forever."
  (let ((remaining codes))
    (lambda ()
      (if remaining (pop remaining) -1))))

(defun collect (codes)
  "Run the accumulator over CODES (terminator appended) and return a byte list."
  (coerce (lem-ncurses/input::collect-bracketed-paste
           (make-feeder (append codes +terminator+)))
          'list))

(deftest plain-payload
  (ok (equal (map 'list #'char-code "hello")
             (collect (map 'list #'char-code "hello")))))

(deftest empty-payload
  (ok (null (collect '()))))

(deftest terminfo-sequences-are-literal-bytes
  ;; ESC[A (KEY_UP) and ESC O P (F1) as raw bytes must be inserted byte-identically
  ;; rather than being read as keys. This is the realistic pasted-ANSI-log case.
  (let ((payload '(27 91 65 27 79 80))) ; ESC [ A  ESC O P
    (ok (equal payload (collect payload)))))

(deftest keycode-over-255-is-dropped-not-crashed
  ;; A translated keycode (KEY_RESIZE = 632) must be ignored, never pushed to the
  ;; (unsigned-byte 8) accumulator (the TF-1 TYPE-ERROR). Surrounding bytes stay.
  (ok (equal '(104 105) ; h i
             (collect '(104 632 105)))))

(deftest failed-partial-terminator-is-flushed
  ;; A partial terminator match that then diverges must flush the matched bytes
  ;; back into the payload verbatim.
  (let ((payload '(97 27 91 50 48 49 98))) ; a ESC [ 2 0 1 b
    (ok (equal payload (collect payload)))))

(deftest timeout-returns-partial-payload
  ;; No terminator at all: the accumulator returns what it saw before timeout.
  (let ((bytes (coerce (lem-ncurses/input::collect-bracketed-paste
                        (make-feeder '(120 121 122))) ; x y z, no terminator
                       'list)))
    (ok (equal '(120 121 122) bytes))))
