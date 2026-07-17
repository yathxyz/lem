(defpackage :lem-ncurses/term
  (:use :cl)
  (:export :get-color-pair
           :update-foreground-color
           :update-background-color
           :background-color
           :term-init
           :term-finalize
           :term-set-tty
           :write-terminal-string
           :term-set-color
           ;;win32 patch
           :get-mouse-mode
           :enable-mouse
           :disable-mouse
           :update-cursor-shape
           :get-display-width
           :get-display-height))
(in-package :lem-ncurses/term)

(cffi:defcvar ("COLOR_PAIRS" *COLOR-PAIRS* :library charms/ll::libcurses) :int)

;; mouse mode
;;   =0: not use mouse
;;   =1: use mouse
(defvar *mouse-mode* #+win32 1 #-win32 0)

;; for mouse
(defun get-mouse-mode ()
  *mouse-mode*)
(defun enable-mouse ()
  (setf *mouse-mode* 1)
  (charms/ll:mousemask (logior charms/ll:all_mouse_events
                               charms/ll:report_mouse_position)))
(defun disable-mouse ()
  (setf *mouse-mode* 0)
  (charms/ll:mousemask 0))

(defun write-terminal-string (string)
  "Write STRING to the controlling terminal, bypassing ncurses' screen buffer.
Used for control sequences ncurses does not manage (bracketed paste, OSC 52
clipboard, mouse toggling). Writes straight to the terminal FILE* and flushes,
so no printf subprocess is forked."
  (let ((fp (terminal-file-pointer)))
    (when fp
      (fputs string fp)
      (fflush fp))))

(defun enable-bracketed-paste ()
  "Ask the terminal to wrap pasted text in ESC[200~ ... ESC[201~ (DEC mode 2004)."
  (write-terminal-string (format nil "~C[?2004h" #\Esc)))

(defun disable-bracketed-paste ()
  "Turn off terminal bracketed paste (DEC mode 2004)."
  (write-terminal-string (format nil "~C[?2004l" #\Esc)))


(defvar *colors*)

(defun term-set-color (index r g b &optional (call-init-color t))
  (when call-init-color
    (charms/ll:init-color index
                          (round (* r 1000/255))
                          (round (* g 1000/255))
                          (round (* b 1000/255))))
  (setf (aref *colors* index) (lem:make-color r g b)))

(defun init-colors (n)

  ;; limit max colors
  (if (> n 256) (setf n 256))

  (let ((counter 0))
    (flet ((add-color (r g b)
             (term-set-color counter r g b (<= 8 counter))
             (incf counter)))
      (setf *colors* (make-array n))
      (add-color #x00 #x00 #x00)
      (add-color #xcd #x00 #x00)
      (add-color #x00 #xcd #x00)
      (add-color #xcd #xcd #x00)
      (add-color #x00 #x00 #xee)
      (add-color #xcd #x00 #xcd)
      (add-color #x00 #xcd #xcd)
      (add-color #xe5 #xe5 #xe5)
      (when (<= 16 n)
        (add-color #x7f #x7f #x7f)
        (add-color #xff #x00 #x00)
        (add-color #x00 #xff #x00)
        (add-color #xff #xff #x00)
        (add-color #x5c #x5c #xff)
        (add-color #xff #x00 #xff)
        (add-color #x00 #xff #xff)
        (add-color #xff #xff #xff))
      (when (<= 256 n)
        (add-color #x00 #x00 #x00)
        (add-color #x00 #x00 #x5f)
        (add-color #x00 #x00 #x87)
        (add-color #x00 #x00 #xaf)
        (add-color #x00 #x00 #xd7)
        (add-color #x00 #x00 #xff)
        (add-color #x00 #x5f #x00)
        (add-color #x00 #x5f #x5f)
        (add-color #x00 #x5f #x87)
        (add-color #x00 #x5f #xaf)
        (add-color #x00 #x5f #xd7)
        (add-color #x00 #x5f #xff)
        (add-color #x00 #x87 #x00)
        (add-color #x00 #x87 #x5f)
        (add-color #x00 #x87 #x87)
        (add-color #x00 #x87 #xaf)
        (add-color #x00 #x87 #xd7)
        (add-color #x00 #x87 #xff)
        (add-color #x00 #xaf #x00)
        (add-color #x00 #xaf #x5f)
        (add-color #x00 #xaf #x87)
        (add-color #x00 #xaf #xaf)
        (add-color #x00 #xaf #xd7)
        (add-color #x00 #xaf #xff)
        (add-color #x00 #xd7 #x00)
        (add-color #x00 #xd7 #x5f)
        (add-color #x00 #xd7 #x87)
        (add-color #x00 #xd7 #xaf)
        (add-color #x00 #xd7 #xd7)
        (add-color #x00 #xd7 #xff)
        (add-color #x00 #xff #x00)
        (add-color #x00 #xff #x5f)
        (add-color #x00 #xff #x87)
        (add-color #x00 #xff #xaf)
        (add-color #x00 #xff #xd7)
        (add-color #x00 #xff #xff)
        (add-color #x5f #x00 #x00)
        (add-color #x5f #x00 #x5f)
        (add-color #x5f #x00 #x87)
        (add-color #x5f #x00 #xaf)
        (add-color #x5f #x00 #xd7)
        (add-color #x5f #x00 #xff)
        (add-color #x5f #x5f #x00)
        (add-color #x5f #x5f #x5f)
        (add-color #x5f #x5f #x87)
        (add-color #x5f #x5f #xaf)
        (add-color #x5f #x5f #xd7)
        (add-color #x5f #x5f #xff)
        (add-color #x5f #x87 #x00)
        (add-color #x5f #x87 #x5f)
        (add-color #x5f #x87 #x87)
        (add-color #x5f #x87 #xaf)
        (add-color #x5f #x87 #xd7)
        (add-color #x5f #x87 #xff)
        (add-color #x5f #xaf #x00)
        (add-color #x5f #xaf #x5f)
        (add-color #x5f #xaf #x87)
        (add-color #x5f #xaf #xaf)
        (add-color #x5f #xaf #xd7)
        (add-color #x5f #xaf #xff)
        (add-color #x5f #xd7 #x00)
        (add-color #x5f #xd7 #x5f)
        (add-color #x5f #xd7 #x87)
        (add-color #x5f #xd7 #xaf)
        (add-color #x5f #xd7 #xd7)
        (add-color #x5f #xd7 #xff)
        (add-color #x5f #xff #x00)
        (add-color #x5f #xff #x5f)
        (add-color #x5f #xff #x87)
        (add-color #x5f #xff #xaf)
        (add-color #x5f #xff #xd7)
        (add-color #x5f #xff #xff)
        (add-color #x87 #x00 #x00)
        (add-color #x87 #x00 #x5f)
        (add-color #x87 #x00 #x87)
        (add-color #x87 #x00 #xaf)
        (add-color #x87 #x00 #xd7)
        (add-color #x87 #x00 #xff)
        (add-color #x87 #x5f #x00)
        (add-color #x87 #x5f #x5f)
        (add-color #x87 #x5f #x87)
        (add-color #x87 #x5f #xaf)
        (add-color #x87 #x5f #xd7)
        (add-color #x87 #x5f #xff)
        (add-color #x87 #x87 #x00)
        (add-color #x87 #x87 #x5f)
        (add-color #x87 #x87 #x87)
        (add-color #x87 #x87 #xaf)
        (add-color #x87 #x87 #xd7)
        (add-color #x87 #x87 #xff)
        (add-color #x87 #xaf #x00)
        (add-color #x87 #xaf #x5f)
        (add-color #x87 #xaf #x87)
        (add-color #x87 #xaf #xaf)
        (add-color #x87 #xaf #xd7)
        (add-color #x87 #xaf #xff)
        (add-color #x87 #xd7 #x00)
        (add-color #x87 #xd7 #x5f)
        (add-color #x87 #xd7 #x87)
        (add-color #x87 #xd7 #xaf)
        (add-color #x87 #xd7 #xd7)
        (add-color #x87 #xd7 #xff)
        (add-color #x87 #xff #x00)
        (add-color #x87 #xff #x5f)
        (add-color #x87 #xff #x87)
        (add-color #x87 #xff #xaf)
        (add-color #x87 #xff #xd7)
        (add-color #x87 #xff #xff)
        (add-color #xaf #x00 #x00)
        (add-color #xaf #x00 #x5f)
        (add-color #xaf #x00 #x87)
        (add-color #xaf #x00 #xaf)
        (add-color #xaf #x00 #xd7)
        (add-color #xaf #x00 #xff)
        (add-color #xaf #x5f #x00)
        (add-color #xaf #x5f #x5f)
        (add-color #xaf #x5f #x87)
        (add-color #xaf #x5f #xaf)
        (add-color #xaf #x5f #xd7)
        (add-color #xaf #x5f #xff)
        (add-color #xaf #x87 #x00)
        (add-color #xaf #x87 #x5f)
        (add-color #xaf #x87 #x87)
        (add-color #xaf #x87 #xaf)
        (add-color #xaf #x87 #xd7)
        (add-color #xaf #x87 #xff)
        (add-color #xaf #xaf #x00)
        (add-color #xaf #xaf #x5f)
        (add-color #xaf #xaf #x87)
        (add-color #xaf #xaf #xaf)
        (add-color #xaf #xaf #xd7)
        (add-color #xaf #xaf #xff)
        (add-color #xaf #xd7 #x00)
        (add-color #xaf #xd7 #x5f)
        (add-color #xaf #xd7 #x87)
        (add-color #xaf #xd7 #xaf)
        (add-color #xaf #xd7 #xd7)
        (add-color #xaf #xd7 #xff)
        (add-color #xaf #xff #x00)
        (add-color #xaf #xff #x5f)
        (add-color #xaf #xff #x87)
        (add-color #xaf #xff #xaf)
        (add-color #xaf #xff #xd7)
        (add-color #xaf #xff #xff)
        (add-color #xd7 #x00 #x00)
        (add-color #xd7 #x00 #x5f)
        (add-color #xd7 #x00 #x87)
        (add-color #xd7 #x00 #xaf)
        (add-color #xd7 #x00 #xd7)
        (add-color #xd7 #x00 #xff)
        (add-color #xd7 #x5f #x00)
        (add-color #xd7 #x5f #x5f)
        (add-color #xd7 #x5f #x87)
        (add-color #xd7 #x5f #xaf)
        (add-color #xd7 #x5f #xd7)
        (add-color #xd7 #x5f #xff)
        (add-color #xd7 #x87 #x00)
        (add-color #xd7 #x87 #x5f)
        (add-color #xd7 #x87 #x87)
        (add-color #xd7 #x87 #xaf)
        (add-color #xd7 #x87 #xd7)
        (add-color #xd7 #x87 #xff)
        (add-color #xd7 #xaf #x00)
        (add-color #xd7 #xaf #x5f)
        (add-color #xd7 #xaf #x87)
        (add-color #xd7 #xaf #xaf)
        (add-color #xd7 #xaf #xd7)
        (add-color #xd7 #xaf #xff)
        (add-color #xd7 #xd7 #x00)
        (add-color #xd7 #xd7 #x5f)
        (add-color #xd7 #xd7 #x87)
        (add-color #xd7 #xd7 #xaf)
        (add-color #xd7 #xd7 #xd7)
        (add-color #xd7 #xd7 #xff)
        (add-color #xd7 #xff #x00)
        (add-color #xd7 #xff #x5f)
        (add-color #xd7 #xff #x87)
        (add-color #xd7 #xff #xaf)
        (add-color #xd7 #xff #xd7)
        (add-color #xd7 #xff #xff)
        (add-color #xff #x00 #x00)
        (add-color #xff #x00 #x5f)
        (add-color #xff #x00 #x87)
        (add-color #xff #x00 #xaf)
        (add-color #xff #x00 #xd7)
        (add-color #xff #x00 #xff)
        (add-color #xff #x5f #x00)
        (add-color #xff #x5f #x5f)
        (add-color #xff #x5f #x87)
        (add-color #xff #x5f #xaf)
        (add-color #xff #x5f #xd7)
        (add-color #xff #x5f #xff)
        (add-color #xff #x87 #x00)
        (add-color #xff #x87 #x5f)
        (add-color #xff #x87 #x87)
        (add-color #xff #x87 #xaf)
        (add-color #xff #x87 #xd7)
        (add-color #xff #x87 #xff)
        (add-color #xff #xaf #x00)
        (add-color #xff #xaf #x5f)
        (add-color #xff #xaf #x87)
        (add-color #xff #xaf #xaf)
        (add-color #xff #xaf #xd7)
        (add-color #xff #xaf #xff)
        (add-color #xff #xd7 #x00)
        (add-color #xff #xd7 #x5f)
        (add-color #xff #xd7 #x87)
        (add-color #xff #xd7 #xaf)
        (add-color #xff #xd7 #xd7)
        (add-color #xff #xd7 #xff)
        (add-color #xff #xff #x00)
        (add-color #xff #xff #x5f)
        (add-color #xff #xff #x87)
        (add-color #xff #xff #xaf)
        (add-color #xff #xff #xd7)
        (add-color #xff #xff #xff)
        (add-color #x08 #x08 #x08)
        (add-color #x12 #x12 #x12)
        (add-color #x1c #x1c #x1c)
        (add-color #x26 #x26 #x26)
        (add-color #x30 #x30 #x30)
        (add-color #x3a #x3a #x3a)
        (add-color #x44 #x44 #x44)
        (add-color #x4e #x4e #x4e)
        (add-color #x58 #x58 #x58)
        (add-color #x62 #x62 #x62)
        (add-color #x6c #x6c #x6c)
        (add-color #x76 #x76 #x76)
        (add-color #x80 #x80 #x80)
        (add-color #x8a #x8a #x8a)
        (add-color #x94 #x94 #x94)
        (add-color #x9e #x9e #x9e)
        (add-color #xa8 #xa8 #xa8)
        (add-color #xb2 #xb2 #xb2)
        (add-color #xbc #xbc #xbc)
        (add-color #xc6 #xc6 #xc6)
        (add-color #xd0 #xd0 #xd0)
        (add-color #xda #xda #xda)
        (add-color #xe4 #xe4 #xe4)
        (add-color #xee #xee #xee)))))

(defun rgb-to-hsv-distance (color-1 color-2)
  (multiple-value-bind (h1 s1 v1) (lem:rgb-to-hsv color-1)
    (multiple-value-bind (h2 s2 v2) (lem:rgb-to-hsv color-2)
      (let ((h (abs (- h1 h2)))
            (s (abs (- s1 s2)))
            (v (abs (- v1 v2))))
        (+ (* h h) (* s s) (* v v))))))

(defun get-color-rgb (color-1)
  (let ((min most-positive-fixnum)
        (best-color)
        (best-number))
    (loop :for color-2 :across *colors*
          :for color-number :from 0
          :do (let ((dist (rgb-to-hsv-distance
                           color-1
                           color-2)))
                (when (< dist min)
                  (setf min dist
                        best-color color-2
                        best-number color-number))))
    best-number))

(defun get-color-1 (string)
  (alexandria:when-let ((color (lem:parse-color string)))
    (get-color-rgb color)))

(defun get-color (string)
  (let ((color (get-color-1 string)))
    (if color
        (values color t)
        (values 0 nil))))


(defvar *pair-counter* 0)
(defvar *color-pair-table* (make-hash-table :test 'equal))

(defun init-pair (pair-color)
  (incf *pair-counter*)
  (charms/ll:init-pair *pair-counter* (car pair-color) (cdr pair-color))
  (setf (gethash pair-color *color-pair-table*)
        (charms/ll:color-pair *pair-counter*)))

(defun get-color-pair (fg-color-name bg-color-name)
  (multiple-value-bind (default-fg default-bg)
      (get-default-colors)
    (let* ((fg-color (if (null fg-color-name)
                         default-fg
                         (get-color fg-color-name)))
           (bg-color (if (null bg-color-name)
                         default-bg
                         (get-color bg-color-name)))
           (pair-color (cons fg-color bg-color)))
      (cond ((gethash pair-color *color-pair-table*))
            ((< *pair-counter* *color-pairs*)
             (init-pair pair-color))
            (t 0)))))

(defun get-default-colors ()
  (cffi:with-foreign-pointer (f (cffi:foreign-type-size '(:pointer :short)))
    (cffi:with-foreign-pointer (b (cffi:foreign-type-size '(:pointer :short)))
      (charms/ll:pair-content 0 f b)
      (values (cffi:mem-ref f :short)
              (cffi:mem-ref b :short)))))

(defun set-default-color (foreground background)
  (let ((fg-color (if foreground (get-color foreground) -1))
        (bg-color (if background (get-color background) -1)))
    (charms/ll:assume-default-colors fg-color
                                     bg-color)))

(defun update-foreground-color (name)
  (multiple-value-bind (fg found) (get-color name)
    (let ((bg (nth-value 1 (get-default-colors))))
      (cond (found
             (charms/ll:assume-default-colors fg bg)
             t)
            (t
             (error "Undefined color: ~A" name))))))

(defun update-background-color (name)
  (multiple-value-bind (bg found) (get-color name)
    (let ((fg (nth-value 0 (get-default-colors))))
      (cond (found
             (charms/ll:assume-default-colors fg bg)
             t)
            (t
             (error "Undefined color: ~A" name))))))

(defun background-color ()
  (let ((b (nth-value 1 (get-default-colors))))
    (if (= b -1)
        (lem:make-color 0 0 0)
        (aref *colors* b))))

;;;

(cffi:defcfun "fopen" :pointer (path :string) (mode :string))
(cffi:defcfun "fclose" :int (fp :pointer))
(cffi:defcfun "fileno" :int (fd :pointer))
(cffi:defcfun "fputs" :int (str :string) (fp :pointer))
(cffi:defcfun "fflush" :int (fp :pointer))

(cffi:defcstruct winsize
  (ws-row :unsigned-short)
  (ws-col :unsigned-short)
  (ws-xpixel :unsigned-short)
  (ws-ypixel :unsigned-short))

(cffi:defcfun ioctl :int
  (fd :int)
  (cmd :int)
  &rest)

(defvar *tty-name* nil)
(defvar *term-io* nil)

(defun resize-term ()
  (when *term-io*
    (cffi:with-foreign-object (ws '(:struct winsize))
      (when (= 0 (ioctl (fileno *term-io*) 21523 :pointer ws))
        (cffi:with-foreign-slots ((ws-row ws-col) ws (:struct winsize))
          (charms/ll:resizeterm ws-row ws-col))))))

(defun term-init-tty (tty-name)
  (let* ((io (fopen tty-name "r+")))
    (setf *term-io* io)
    (cffi:with-foreign-string (term "xterm")
      (charms/ll:newterm term io io))))

(cffi:defcfun "key_defined" :int (definition :string))

(defparameter +modified-key-finals+ "ABCDEFHPQRS"
  "CSI final bytes for the modified cursor/function family, matching the parser's
+csi-final-syms+ (ESC[1;<mod><final>).")

(defparameter +modified-key-tilde-numbers+
  '(1 2 3 4 5 6 7 8 11 12 13 14 15 17 18 19 20 21 23 24)
  "Leading parameters of the modified navigation/function family (ESC[<n>;<mod>~),
matching the parser's +csi-tilde-syms+.")

(defun disable-modified-key-translation ()
  "Stop ncurses from translating terminfo-known *modified* key escape sequences
(Ctrl/Alt/Shift + cursor, navigation, and function keys) into keycodes, so their
raw bytes reach lem-ncurses/input's CSI parser instead. Without this, whether a
modified key like Shift-F5 or Shift-Left is parsed depends on the terminfo entry:
ncurses collapses the ones it knows (kf17, kLFT, ...) into extended keycodes that
never enter the CSI parser. Plain unmodified keys keep their keypad translation,
so KEY_RESIZE and ordinary special keys are unaffected. keyok operates on the
global key trie, so it also governs the input pad used for reading."
  (flet ((disable (seq)
           ;; key-defined returns the assigned keycode for a complete key,
           ;; 0 when undefined, or -1 for an ambiguous prefix; only disable
           ;; complete keys so raw bytes flow through to the parser.
           (let ((code (key-defined seq)))
             (when (plusp code)
               ;; enable=0 (FALSE): charms' bool maps a C bool, so pass an int.
               (charms/ll:keyok code 0)))))
    (loop :for modifier :from 2 :to 8
          :do (loop :for final :across +modified-key-finals+
                    :do (disable (format nil "~C[1;~D~C" #\Esc modifier final)))
              (loop :for n :in +modified-key-tilde-numbers+
                    :do (disable (format nil "~C[~D;~D~C" #\Esc n modifier #\~))))))

(defun term-init ()
  (cl-setlocale:set-all-to-native)
  (if *tty-name*
      (term-init-tty *tty-name*)
      (charms/ll:initscr))
  (when (zerop (charms/ll:has-colors))
    (charms/ll:endwin)
    (write-line "Please execute TERM=xterm-256color and try again.")
    (return-from term-init nil))
  (charms/ll:start-color)
  ;; enable default color code (-1)
  #+win32(charms/ll:use-default-colors)
  (init-colors charms/ll:*colors*)
  (set-default-color nil nil)
  (charms/ll:noecho)
  (charms/ll:cbreak)
  (charms/ll:raw)
  (charms/ll:nonl)
  (charms/ll:refresh)
  (charms/ll:keypad charms/ll:*stdscr* 1)
  (disable-modified-key-translation)
  (setf charms/ll::*escdelay* 0)
  ;; (charms/ll:curs-set 0)
  ;; for mouse
  (when (= *mouse-mode* 1)
    (enable-mouse))
  (enable-bracketed-paste)
  t)

(defun term-set-tty (tty-name)
  (setf *tty-name* tty-name))

(defun term-finalize ()
  (disable-bracketed-paste)
  (when *term-io*
    (fclose *term-io*)
    (setf *term-io* nil))
  (charms/ll:endwin)
  (charms/ll:delscreen charms/ll:*stdscr*))

(defun terminal-file-pointer ()
  "Return a C FILE* for the controlling terminal.
Prefer the tty opened by term-init-tty; otherwise fall back to the C stdout
that ncurses' default screen writes to."
  (or *term-io*
      (let ((p (cffi:foreign-symbol-pointer "stdout")))
        (and p (cffi:mem-ref p :pointer)))))

(defun update-cursor-shape (cursor-type)
  "Set the terminal cursor shape via DECSCUSR (ESC[<n> q).
Writes the sequence straight to the terminal FILE* and flushes, avoiding a
printf subprocess fork on every cursor-shape change (e.g. the vi-mode
insert/normal toggle)."
  (check-type cursor-type lem:cursor-type)
  (let ((fp (terminal-file-pointer)))
    (when fp
      (fputs (format nil "~C[~D q"
                     #\Esc
                     (case cursor-type
                       (:box 2)
                       (:bar 5)
                       (:underline 4)
                       (otherwise 2)))
             fp)
      (fflush fp))))

(defun get-display-width ()
  (max 5 charms/ll:*cols*))

(defun get-display-height ()
  (max 3 charms/ll:*lines*))
