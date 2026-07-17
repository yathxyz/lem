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

(defun csi\[1 ()
  (or (case (getch)
        (#.(char-code #\;)
           (case (getch)
             (#.(char-code #\2)
                (case (getch)
                  (#.(char-code #\A) (make-key :shift t :sym "Up"))
                  (#.(char-code #\B) (make-key :shift t :sym "Down"))
                  (#.(char-code #\C) (make-key :shift t :sym "Right"))
                  (#.(char-code #\D) (make-key :shift t :sym "Left"))
                  (#.(char-code #\F) (make-key :shift t :sym "End"))
                  (#.(char-code #\H) (make-key :shift t :sym "Home"))))
             (#.(char-code #\3)
                (case (getch)
                  (#.(char-code #\A) (make-key :meta t :sym "Up"))
                  (#.(char-code #\B) (make-key :meta t :sym "Down"))
                  (#.(char-code #\C) (make-key :meta t :sym "Right"))
                  (#.(char-code #\D) (make-key :meta t :sym "Left"))
                  (#.(char-code #\F) (make-key :meta t :sym "End"))
                  (#.(char-code #\H) (make-key :meta t :sym "Home"))))
             (#.(char-code #\4)
                (case (getch)
                  (#.(char-code #\A) (make-key :shift t :meta t :sym "Up"))
                  (#.(char-code #\B) (make-key :shift t :meta t :sym "Down"))
                  (#.(char-code #\C) (make-key :shift t :meta t :sym "Right"))
                  (#.(char-code #\D) (make-key :shift t :meta t :sym "Left"))
                  (#.(char-code #\F) (make-key :shift t :meta t :sym "End"))
                  (#.(char-code #\H) (make-key :shift t :meta t :sym "Home"))))
             (#.(char-code #\5)
                (case (getch)
                  (#.(char-code #\A) (make-key :ctrl t :sym "Up"))
                  (#.(char-code #\B) (make-key :ctrl t :sym "Down"))
                  (#.(char-code #\C) (make-key :ctrl t :sym "Right"))
                  (#.(char-code #\D) (make-key :ctrl t :sym "Left"))
                  (#.(char-code #\F) (make-key :ctrl t :sym "End"))
                  (#.(char-code #\H) (make-key :ctrl t :sym "Home"))))
             (#.(char-code #\6)
                (case (getch)
                  (#.(char-code #\A) (make-key :shift t :ctrl t :sym "Up"))
                  (#.(char-code #\B) (make-key :shift t :ctrl t :sym "Down"))
                  (#.(char-code #\C) (make-key :shift t :ctrl t :sym "Right"))
                  (#.(char-code #\D) (make-key :shift t :ctrl t :sym "Left"))
                  (#.(char-code #\F) (make-key :shift t :ctrl t :sym "End"))
                  (#.(char-code #\H) (make-key :shift t :ctrl t :sym "Home"))))
             (#.(char-code #\7)
                (case (getch)
                  (#.(char-code #\A) (make-key :meta t :ctrl t :sym "Up"))
                  (#.(char-code #\B) (make-key :meta t :ctrl t :sym "Down"))
                  (#.(char-code #\C) (make-key :meta t :ctrl t :sym "Right"))
                  (#.(char-code #\D) (make-key :meta t :ctrl t :sym "Left"))
                  (#.(char-code #\F) (make-key :meta t :ctrl t :sym "End"))
                  (#.(char-code #\H) (make-key :meta t :ctrl t :sym "Home"))))
             (#.(char-code #\8)
                (case (getch)
                  (#.(char-code #\A) (make-key :shift t :meta t :ctrl t :sym "Up"))
                  (#.(char-code #\B) (make-key :shift t :meta t :ctrl t :sym "Down"))
                  (#.(char-code #\C) (make-key :shift t :meta t :ctrl t :sym "Right"))
                  (#.(char-code #\D) (make-key :shift t :meta t :ctrl t :sym "Left"))
                  (#.(char-code #\F) (make-key :shift t :meta t :ctrl t :sym "End"))
                  (#.(char-code #\H) (make-key :shift t :meta t :ctrl t :sym "Home")))))))
      (get-key-from-name "escape")))

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

(defun csi\[2 ()
  "Handle CSI sequences beginning with ESC[2.
Only bracketed paste (ESC[200~) is recognized; other ESC[2... sequences
fall back to Escape."
  (if (and (= (getch) #.(char-code #\0))
           (= (getch) #.(char-code #\0))
           (= (getch) #.(char-code #\~)))
      (read-bracketed-paste)
      (get-key-from-name "escape")))

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
                            (case (getch)
                              (#.(char-code #\<)
                                 ;;sgr(1006)
                                 (uiop:symbol-call :lem-mouse-sgr1006
                                                   :parse-mouse-event
                                                   #'getch))
                              (#.(char-code #\1)
                                 (csi\[1))
                              (#.(char-code #\2)
                                 (csi\[2))
                              (t (get-key-from-name "escape")))))
                         (t
                          (let ((key (get-key code)))
                            (make-key :meta t
                                      :sym (key-sym key)
                                      :ctrl (key-ctrl key)))))))
                (t
                 (get-key code))))))))
