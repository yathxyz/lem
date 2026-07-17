;;;; SPEC-VK VK-10 one-source swap.  char-width / string-width / wide-index are
;;;; now THIN SHELLS over the ACL2-certified width kernel (verified/width.lisp),
;;;; loaded into this image through verified/shim.lisp by the lem-verified-kernel
;;;; system (a lem/core dependency).  The per-codepoint arithmetic, the tab-stop
;;;; law, the *char-replacement* control widths and the East-Asian range tables
;;;; live once, in the kernel; this file only iterates strings (char-code per
;;;; char, NO per-call codepoint-list allocation -- string-width is redisplay-hot)
;;;; and threads in the two pieces of DYNAMIC state the kernel cannot hold:
;;;; *ambiguous-character-width* and the runtime icon table (icon-code-p).
;;;;
;;;; Behavior is identical to the pre-swap implementation: tests/string-width-utils.lisp
;;;; passes unchanged, and the certified kernel reproduces every one of the frozen
;;;; tests/pbt/width-vectors.lisp regression vectors (captured from this file's
;;;; previous version).  control-char / wide-char-p are kept as the exported
;;;; classification helpers other code and tests import; they are no longer on
;;;; char-width's path (the kernel classifies internally).

(defpackage :lem/common/character/string-width-utils
  (:use :cl)
  (:export :+default-tab-size+
           :*ambiguous-character-width*
           :control-char
           :wide-char-p
           :char-width
           :string-width
           :wide-index))
(in-package :lem/common/character/string-width-utils)

(defconstant +default-tab-size+ 8)

(defvar *ambiguous-character-width* 1
  "Display width for East_Asian_Width \"Ambiguous\" characters.
The default 1 (narrow) preserves legacy behavior; bind or set it to 2 for a
terminal configured to render ambiguous-width characters as wide (CJK).")

(defparameter *char-replacement*
  (let ((table (make-hash-table)))
    (setf (gethash (code-char 0) table) "^@")
    (setf (gethash (code-char 1) table) "^A")
    (setf (gethash (code-char 2) table) "^B")
    (setf (gethash (code-char 3) table) "^C")
    (setf (gethash (code-char 4) table) "^D")
    (setf (gethash (code-char 5) table) "^E")
    (setf (gethash (code-char 6) table) "^F")
    (setf (gethash (code-char 7) table) "^G")
    (setf (gethash (code-char 8) table) "^H")
    (setf (gethash (code-char 9) table) "^I")
    (setf (gethash (code-char 11) table) "^K")
    (setf (gethash (code-char 12) table) "^L")
    (setf (gethash (code-char 13) table) "^R")
    (setf (gethash (code-char 14) table) "^N")
    (setf (gethash (code-char 15) table) "^O")
    (setf (gethash (code-char 16) table) "^P")
    (setf (gethash (code-char 17) table) "^Q")
    (setf (gethash (code-char 18) table) "^R")
    (setf (gethash (code-char 19) table) "^S")
    (setf (gethash (code-char 20) table) "^T")
    (setf (gethash (code-char 21) table) "^U")
    (setf (gethash (code-char 22) table) "^V")
    (setf (gethash (code-char 23) table) "^W")
    (setf (gethash (code-char 24) table) "^X")
    (setf (gethash (code-char 25) table) "^Y")
    (setf (gethash (code-char 26) table) "^Z")
    (setf (gethash (code-char 27) table) "^[")
    (setf (gethash (code-char 28) table) "^\\")
    (setf (gethash (code-char 29) table) "^]")
    (setf (gethash (code-char 30) table) "^^")
    (setf (gethash (code-char 31) table) "^_")
    (setf (gethash (code-char 127) table) "^?")
    (loop :for i :from 0 :to #xff
          :do (setf (gethash (code-char (+ #xe000 i)) table)
                    (format nil "\\~D" i)))
    table))

(defun control-char (char)
  (gethash char *char-replacement*))

(defun wide-char-p (char)
  (declare (character char))
  (or (char= char #\▼)
      (lem/common/character/icon:icon-code-p (char-code char))
      (lem/common/character/eastasian:eastasian-code-p (char-code char))
      (control-char char)))

;;; ---------------------------------------------------------------------------
;;; Kernel bridge (verified/width.lisp, via verified/shim.lisp)
;;; ---------------------------------------------------------------------------

(declaim (inline %char-width-step))
(defun %char-width-step (code width tab-size)
  "The certified per-codepoint width step: new column after placing CODE at
column WIDTH.  Threads in the two dynamic overlays the kernel cannot hold --
the runtime icon table and *ambiguous-character-width*."
  (declare (fixnum code width tab-size))
  (lem/kernel:k-char-width code width tab-size
                           (lem/common/character/icon:icon-code-p code)
                           *ambiguous-character-width*))

(defun char-width (char width &key (tab-size +default-tab-size+))
  (declare (character char) (fixnum width))
  (%char-width-step (char-code char) width tab-size))

(defun string-width (string &key (start 0) end (tab-size +default-tab-size+))
  (let* ((len (length string))
         (safe-end (min (or end len) len)))
    (declare (fixnum len safe-end))
    (loop :with width fixnum := 0
          :for index :from start :below safe-end
          :do (setq width (%char-width-step (char-code (char string index))
                                            width tab-size))
          :finally (return width))))

(defun wide-index (string goal &key (start 0) (tab-size +default-tab-size+))
  (loop :with width fixnum := 0
        :for index :from start :below (length string)
        :do (setq width (%char-width-step (char-code (char string index))
                                          width tab-size))
            (when (< goal width)
              (return index))))
