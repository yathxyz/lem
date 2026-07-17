(defpackage :lem-ncurses/input
  (:use :cl
        :lem
        :lem-ncurses/key)
  (:export :get-event))
(in-package :lem-ncurses/input)

;; for input
;;  (we don't use stdscr for input because it calls wrefresh implicitly
;;   and causes the display confliction by two threads)
(defvar *padwin* nil)

(defun getch ()
  (unless *padwin*
    (setf *padwin* (charms/ll:newpad 1 1))
    (charms/ll:keypad *padwin* 1)
    (charms/ll:wtimeout *padwin* -1))
  (charms/ll:wgetch *padwin*))

(defmacro with-getch-input-timeout ((time) &body body)
  `(progn
     (charms/ll:wtimeout *padwin* ,time)
     (unwind-protect (progn ,@body)
       (charms/ll:wtimeout *padwin* -1))))

(defun utf8-bytes (c)
  (cond
    ((<= c #x7f) 1)
    ((<= #xc2 c #xdf) 2)
    ((<= #xe0 c #xef) 3)
    ((<= #xf0 c #xf4) 4)
    (t 1)))

(defun get-key (code)
  (let* ((char (let ((nbytes (utf8-bytes code)))
                 (if (= nbytes 1)
                     (code-char code)
                     (let ((vec (make-array nbytes :element-type '(unsigned-byte 8))))
                       (setf (aref vec 0) code)
                       (with-getch-input-timeout (100)
                         (loop :for i :from 1 :below nbytes
                               :do (setf (aref vec i) (getch))))
                       (handler-case (schar (babel:octets-to-string vec) 0)
                         (babel-encodings:invalid-utf8-continuation-byte ()
                           (code-char code)))))))
         (key (char-to-key char)))
    key))

(defparameter +bracketed-paste-end+
  (coerce (list #.(char-code #\Esc)
                #.(char-code #\[)
                #.(char-code #\2)
                #.(char-code #\0)
                #.(char-code #\1)
                #.(char-code #\~))
          '(simple-array (unsigned-byte 8) (*)))
  "Byte sequence ESC[201~ that terminates a bracketed paste.")

(defun read-bracketed-paste ()
  "Read a bracketed-paste payload after the ESC[200~ introducer.
Accumulate raw octets from the terminal until the ESC[201~ terminator,
UTF-8 decode them, and return an event closure that inserts the text as a
single undo unit without running keymaps, auto-indent, or abbrev. Any ESC
byte inside the payload is treated as literal text, not as a key."
  (let ((bytes (make-array 64 :element-type '(unsigned-byte 8)
                              :adjustable t :fill-pointer 0))
        (match 0)
        (terminator-length (length +bracketed-paste-end+)))
    (with-getch-input-timeout (1000)
      (loop
        (let ((code (getch)))
          (cond
            ((< code 0)
             ;; timed out before the terminator arrived; stop with what we have.
             (return))
            ((= code (aref +bracketed-paste-end+ match))
             (incf match)
             (when (= match terminator-length)
               (return)))
            (t
             ;; a partial terminator match failed: the matched bytes were real
             ;; payload, so flush them and reconsider the current byte.
             (loop :for i :from 0 :below match
                   :do (vector-push-extend (aref +bracketed-paste-end+ i) bytes))
             (if (= code (aref +bracketed-paste-end+ 0))
                 (setf match 1)
                 (progn
                   (setf match 0)
                   (vector-push-extend code bytes))))))))
    (let ((text (babel:octets-to-string bytes :encoding :utf-8 :errorp nil)))
      (lambda ()
        (lem:insert-bracketed-paste (lem:current-point) text)))))

(defun decode-csi-modifier (mod)
  "Decode an xterm CSI modifier parameter into (values shift meta ctrl).
MOD is the numeric parameter where 1 (or NIL) means no modifier. The encoding
is 1 + a bitmask of Shift=1, Alt(Meta)=2, Ctrl=4, so 2=Shift, 3=Alt,
4=Alt+Shift, 5=Ctrl, 6=Ctrl+Shift, 7=Ctrl+Alt, 8=Ctrl+Alt+Shift."
  (let ((bits (max 0 (- (or mod 1) 1))))
    (values (logbitp 0 bits)
            (logbitp 1 bits)
            (logbitp 2 bits))))

(defparameter +csi-final-syms+
  '((#\A . "Up") (#\B . "Down") (#\C . "Right") (#\D . "Left")
    (#\F . "End") (#\H . "Home")
    (#\P . "F1") (#\Q . "F2") (#\R . "F3") (#\S . "F4"))
  "Map a CSI 1;<mod> final byte (A-F/H/P-S) to a lem key sym.")

(defparameter +csi-tilde-syms+
  '((1 . "Home") (2 . "Insert") (3 . "Delete") (4 . "End")
    (5 . "PageUp") (6 . "PageDown") (7 . "Home") (8 . "End")
    (11 . "F1") (12 . "F2") (13 . "F3") (14 . "F4")
    (15 . "F5") (17 . "F6") (18 . "F7") (19 . "F8")
    (20 . "F9") (21 . "F10") (23 . "F11") (24 . "F12"))
  "Map the first parameter of a CSI <n>;<mod>~ sequence to a lem key sym.")

(defun make-modified-key (sym mod)
  "Build a lem key for SYM with the modifiers encoded in the CSI parameter MOD."
  (multiple-value-bind (shift meta ctrl) (decode-csi-modifier mod)
    (make-key :shift shift :meta meta :ctrl ctrl :sym sym)))

(defun csi-param (params index)
  "Return the INDEX-th parameter of the vector PARAMS, or NIL if absent."
  (when (< index (length params))
    (aref params index)))

(defun dispatch-csi (final params)
  "Dispatch a fully-read CSI sequence.
FINAL is the final byte as a character; PARAMS is a vector of numeric
parameters (each NIL when the field was empty). Handles the modified
cursor/function family (ESC[1;<mod><A-F/H/P-S>), the modified navigation
family (ESC[<n>;<mod>~), and bracketed paste (ESC[200~). Unknown sequences
fall back to Escape so a stray or unsupported sequence is swallowed harmlessly."
  (case final
    (#\~
     (let ((n (or (csi-param params 0) 1))
           (mod (csi-param params 1)))
       (cond
         ((= n 200) (read-bracketed-paste))
         (t (let ((sym (cdr (assoc n +csi-tilde-syms+))))
              (if sym
                  (make-modified-key sym mod)
                  (get-key-from-name "escape")))))))
    (t
     (let ((sym (cdr (assoc final +csi-final-syms+)))
           (mod (csi-param params 1)))
       (if sym
           (make-modified-key sym mod)
           (get-key-from-name "escape"))))))

(defun read-csi (first-byte)
  "Read a CSI sequence after the ESC[ introducer and its FIRST-BYTE are known.
Accumulate the numeric parameters (separated by ';') until a final byte in
0x40-0x7E, then dispatch. Any unexpected byte or a timeout aborts the read and
falls back to Escape, keeping the editor responsive to malformed input."
  (let ((params (make-array 4 :adjustable t :fill-pointer 0))
        (cur nil)
        (byte first-byte))
    (loop
      (cond
        ((or (null byte) (minusp byte))
         (return (get-key-from-name "escape")))
        ((<= #.(char-code #\0) byte #.(char-code #\9))
         (setf cur (+ (* (or cur 0) 10) (- byte #.(char-code #\0)))))
        ((= byte #.(char-code #\;))
         (vector-push-extend cur params)
         (setf cur nil))
        ((<= #x40 byte #x7e)
         (vector-push-extend cur params)
         (return (dispatch-csi (code-char byte) params)))
        (t
         (return (get-key-from-name "escape"))))
      (setf byte (getch)))))

(let ((resize-code (get-code "[resize]"))
      (abort-code (get-code "C-]"))
      (escape-code (get-code "escape")))
  (defun get-event ()
    (tagbody :start
      (return-from get-event
        (let ((code (getch)))
          (cond ((= code -1) (go :start))
                ((= code resize-code) :resize)
                ((= code abort-code) :abort)
                ((= code escape-code)
                 (let ((code (with-getch-input-timeout
                                 ((variable-value 'lem-ncurses/config:escape-delay))
                               (getch))))
                   (cond ((= code -1)
                          (get-key-from-name "escape"))
                         ((= code #.(char-code #\[))
                          (with-getch-input-timeout (100)
                            (let ((c (getch)))
                              (if (= c #.(char-code #\<))
                                  ;; sgr(1006) mouse
                                  (or (lem-ncurses/mouse:read-sgr-mouse-event #'getch)
                                      (go :start))
                                  (read-csi c)))))
                         (t
                          (let ((key (get-key code)))
                            (make-key :meta t
                                      :sym (key-sym key)
                                      :ctrl (key-ctrl key)))))))
                (t
                 (get-key code))))))))
