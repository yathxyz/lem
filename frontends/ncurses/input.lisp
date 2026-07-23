(defpackage :lem-ncurses/input
  (:use :cl
        :lem
        :lem-ncurses/key)
  (:export :get-event
           :decode-csi-key))
(in-package :lem-ncurses/input)

;; for input
;;  (we don't use stdscr for input because it calls wrefresh implicitly
;;   and causes the display confliction by two threads)
(defvar *padwin* nil)
(defvar *wait-for-terminal-input-p* t)

(defun getch ()
  (lem-ncurses/term:with-input-resize-lock
    (unless *padwin*
      (setf *padwin* (charms/ll:newpad 1 1))
      (charms/ll:keypad *padwin* 1)
      (charms/ll:wtimeout *padwin* 0)))
  (when *wait-for-terminal-input-p*
    (lem-ncurses/term:wait-for-input))
  (lem-ncurses/term:with-input-resize-lock
    (charms/ll:wgetch *padwin*)))

(defmacro with-getch-input-timeout ((time) &body body)
  `(let ((*wait-for-terminal-input-p* nil))
     (lem-ncurses/term:with-input-resize-lock
       (charms/ll:wtimeout *padwin* ,time))
     (unwind-protect (progn ,@body)
       (lem-ncurses/term:with-input-resize-lock
         (charms/ll:wtimeout *padwin* 0)))))

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

(defun collect-bracketed-paste (next-byte)
  "Accumulate the raw octets of a bracketed-paste payload.
NEXT-BYTE is a thunk returning the next input code: a byte 0-255, a negative
value on timeout, or a keypad-translated keycode >= 256 (e.g. KEY_RESIZE) which
is ignored because it can never be part of a byte payload. Reading stops at the
ESC[201~ terminator or on timeout. Any ESC byte inside the payload is literal
text, not a key. Returns the payload as an (unsigned-byte 8) vector.

This is a thin I/O driver over the certified kernel state machine
(verified/input-decode.lisp k-paste-step, SPEC-VK VK-7): the terminator
matching, partial-match flushing and keycode dropping are the ACL2-verified
code itself, loaded through verified/shim.lisp."
  (let ((state (lem/kernel:k-paste-init)))
    (loop
      (let ((code (funcall next-byte)))
        (multiple-value-bind (next-state done)
            (lem/kernel:k-paste-step state
                                     (cond ((< code 0) :timeout)
                                           ((> code 255) (list :code code))
                                           (t code)))
          (setf state next-state)
          (when done (return)))))
    (let ((payload (lem/kernel:k-paste-payload state)))
      (make-array (length payload)
                  :element-type '(unsigned-byte 8)
                  :initial-contents payload))))

(defun read-bracketed-paste ()
  "Read a bracketed-paste payload after the ESC[200~ introducer.
Accumulate raw octets from the terminal until the ESC[201~ terminator,
UTF-8 decode them, and return an event closure that inserts the text as a
single undo unit without running keymaps, auto-indent, or abbrev. Any ESC
byte inside the payload is treated as literal text, not as a key.

Keypad translation is disabled on the input pad for the duration of the read so
terminfo-recognized sequences in the payload (ESC[A, ESC OP, ...) arrive as raw
bytes rather than translated keycodes >= 256, which would both corrupt the
payload and crash on the (unsigned-byte 8) accumulator. It is restored
afterwards regardless of how the read exits."
  (let ((bytes (unwind-protect
                    (progn
                      (charms/ll:keypad *padwin* 0)
                      (with-getch-input-timeout (1000)
                        (collect-bracketed-paste #'getch)))
                 (charms/ll:keypad *padwin* 1))))
    (let ((text (babel:octets-to-string bytes :encoding :utf-8 :errorp nil)))
      (lambda ()
        (lem:insert-bracketed-paste (lem:current-point) text)))))

(defun csi-param (params index)
  "Return the INDEX-th parameter of the vector PARAMS, or NIL if absent."
  (when (< index (length params))
    (aref params index)))

(defun kernel-key-event->key (event)
  "Convert a verified-kernel key event record (:key sym shift meta ctrl), whose
sym is a codepoint list, to a lem key."
  (make-key :shift (and (lem/kernel:key-ev-shift event) t)
            :meta (and (lem/kernel:key-ev-meta event) t)
            :ctrl (and (lem/kernel:key-ev-ctrl event) t)
            :sym (map 'string #'code-char (lem/kernel:key-ev-sym event))))

(defun decode-csi-key (final params)
  "Decode a CSI sequence into a lem key, or NIL when it is not a key this parser
recognises (bracketed paste, or an unknown final byte / parameter). FINAL is the
final byte as a character; PARAMS is a vector of numeric parameters (each NIL
when the field was empty). Handles the modified cursor/function family
(ESC[1;<mod><A-F/H/P-S>) and the modified navigation family (ESC[<n>;<mod>~).
The sym/modifier tables and the decode itself are the certified kernel decoder
(verified/input-decode.lisp k-decode-csi-key, SPEC-VK VK-7); this wrapper only
converts characters to codepoints and the kernel key record to a lem key."
  (let ((event (lem/kernel:k-decode-csi-key (char-code final)
                                            (coerce params 'list))))
    (when event
      (kernel-key-event->key event))))

(defun dispatch-csi (final params)
  "Dispatch a fully-read CSI sequence.
Bracketed paste (ESC[200~) is handled by reading its payload; every other
recognised sequence is decoded by DECODE-CSI-KEY. Unknown sequences fall back to
Escape so a stray or unsupported sequence is swallowed harmlessly."
  (if (and (eql final #\~) (eql (csi-param params 0) 200))
      (read-bracketed-paste)
      (or (decode-csi-key final params)
          (get-key-from-name "escape"))))

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
                ((= code resize-code)
                 #+sbcl (go :start)
                 #-sbcl :resize)
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
