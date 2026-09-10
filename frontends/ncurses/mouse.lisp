(defpackage :lem-ncurses/mouse
  (:use :cl :lem)
  (:export :read-sgr-mouse-event
           :decode-sgr-mouse-event
           :enable-mouse-reporting
           :disable-mouse-reporting
           :*mouse-event-handler*
           :toggle-mouse))
(in-package :lem-ncurses/mouse)

;;; SGR-1006 mouse decoding for the terminal frontend.
;;;
;;; xterm's SGR (1006) extended mouse reports arrive as
;;;   ESC [ < <button> ; <col> ; <row> (M|m)
;;; where <col>/<row> are 1-based, `M` is a press/motion and `m` a release.
;;; <button> packs the button number in its low two bits plus flag bits:
;;; #x04 shift, #x08 meta, #x10 ctrl, #x20 motion, #x40 wheel.
;;; We decode into the core mouse events (RECEIVE-MOUSE-*), the same plumbing
;;; the SDL2 frontend feeds, rather than inventing terminal-specific handling.

(defconstant +sgr-motion-flag+ #x20)
(defconstant +sgr-wheel-flag+ #x40)

(defvar *mouse-event-handler*
  (lambda (kind x y button wheel-x wheel-y)
    (lambda ()
      (ecase kind
        (:down (receive-mouse-button-down x y x y button 1))
        (:up (receive-mouse-button-up x y x y button))
        (:move (receive-mouse-motion x y x y button))
        (:wheel (receive-mouse-wheel x y x y wheel-x wheel-y)))))
  "Convert a decoded mouse report into a core event or a native client message.")

(defun sgr-button-keyword (button)
  "Map the low two bits of an SGR button field to a core mouse-button keyword,
or NIL when no button is pressed (motion with button field 3)."
  (case (logand button #x03)
    (0 :button-1)
    (1 :button-2)
    (2 :button-3)
    (t nil)))

(defun decode-sgr-mouse-event (button col row final)
  "Turn a parsed SGR-1006 report into an event closure, or NIL to ignore it.
BUTTON is the numeric button/flag field, COL and ROW are 1-based, and FINAL is
the terminating character (#\\M for press/motion, #\\m for release). The closure
calls the matching RECEIVE-MOUSE-* function when evaluated on the editor thread."
  (let ((x (max 0 (1- col)))
        (y (max 0 (1- row))))
    (cond
      ;; wheel: low bits 0 = up, 1 = down. Positive wheel-y scrolls toward the
      ;; top of the buffer (see HANDLE-MOUSE-EVENT for MOUSE-WHEEL).
      ((logtest button +sgr-wheel-flag+)
       (destructuring-bind (wheel-x wheel-y)
           (aref #((0 1) (0 -1) (-1 0) (1 0)) (logand button #x03))
         (funcall *mouse-event-handler* :wheel x y nil wheel-x wheel-y)))
      ;; motion (with or without a button held down).
      ((logtest button +sgr-motion-flag+)
       (let ((mouse-button (sgr-button-keyword button)))
         (funcall *mouse-event-handler* :move x y mouse-button 0 0)))
      ;; plain press or release.
      (t
       (let ((mouse-button (sgr-button-keyword button)))
         (when mouse-button
           (if (char= final #\M)
               (funcall *mouse-event-handler* :down x y mouse-button 0 0)
               (funcall *mouse-event-handler* :up x y mouse-button 0 0))))))))

(defun read-sgr-mouse-event (getch-fn)
  "Read the rest of an SGR-1006 mouse sequence after the ESC[< introducer and
return an event closure, or NIL. GETCH-FN returns the next input byte code (a
negative value on timeout). The whole sequence is always consumed so that a
disabled mouse cannot leave stray bytes in the input stream; the event is only
produced when MOUSE-MODE is enabled."
  (let ((numbers '())
        (current 0)
        (count 0)
        (final nil))
    (loop
      (let ((c (funcall getch-fn)))
        (cond ((minusp c) (return))
              ((<= #.(char-code #\0) c #.(char-code #\9))
               (setf current (+ (* current 10) (- c #.(char-code #\0)))))
              ((= c #.(char-code #\;))
               (push current numbers)
               (incf count)
               (setf current 0))
              ((or (= c #.(char-code #\M))
                   (= c #.(char-code #\m)))
               (push current numbers)
               (incf count)
               (setf final (code-char c))
               (return))
              ;; malformed: stop consuming, drop the sequence.
              (t (return)))))
    (when (and final
               (= count 3)
               (variable-value 'lem:mouse-mode :global))
      (destructuring-bind (row col button) numbers ; NUMBERS is reversed
        (decode-sgr-mouse-event button col row final)))))

;;; Terminal enable/disable and the user-facing toggle.

(defun enable-mouse-reporting ()
  "Ask the terminal to report mouse events using SGR-1006 extended coordinates.
Enables normal, button-event (drag) and SGR modes."
  (lem-ncurses/term:write-terminal-string
   (format nil "~C[?1000h~C[?1002h~C[?1006h" #\Esc #\Esc #\Esc)))

(defun disable-mouse-reporting ()
  "Stop terminal mouse reporting, restoring native selection and copy/paste."
  (lem-ncurses/term:write-terminal-string
   (format nil "~C[?1006l~C[?1002l~C[?1000l" #\Esc #\Esc #\Esc)))

(define-command toggle-mouse () ()
  "Toggle terminal mouse support. When on, clicking moves point and the wheel
scrolls; when off, the terminal keeps native text selection and copy/paste."
  (cond ((variable-value 'lem:mouse-mode :global)
         (setf (variable-value 'lem:mouse-mode :global) nil)
         (disable-mouse-on-exit)
         (message "Mouse disabled"))
        (t
         (setf (variable-value 'lem:mouse-mode :global) t)
         (enable-mouse-on-startup)
         (message "Mouse enabled"))))

(defun enable-mouse-on-startup ()
  (when (and (eq :ncurses (lem-core::implementation-name (implementation)))
             (variable-value 'lem:mouse-mode :global))
    (enable-mouse-reporting)))

(defun disable-mouse-on-exit ()
  (when (eq :ncurses (lem-core::implementation-name (implementation)))
    (disable-mouse-reporting)))

(add-hook *after-init-hook* 'enable-mouse-on-startup)
(add-hook *exit-editor-hook* 'disable-mouse-on-exit)
