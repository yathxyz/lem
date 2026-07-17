(defpackage :lem-ncurses/clipboard
  (:use :cl :alexandria)
  (:export :copy
           :paste))
(in-package :lem-ncurses/clipboard)

(defparameter *unix-copy-commands*
  '(("wl-copy")
    ("xsel" "--input" "--clipboard")
    ("xclip" "-in" "-selection" "clipboard")))

(defparameter *unix-paste-commands*
  '(("wl-paste")
    ("xsel" "--output" "--clipboard")
    ("xclip" "-out" "-selection" "clipboard")))

(defun execute-copy (command text)
  (with-input-from-string (input text)
    (uiop:run-program command :input input))
  (values))

(defun execute-paste (command)
  (with-output-to-string (output)
    (uiop:run-program command :output output)))

(defgeneric copy-aux (os text))
(defgeneric paste-aux (os))

(defclass os () ())

;;;
(defclass mac (os) ())

(defmethod copy-aux ((os mac) text)
  (execute-copy '("pbcopy") text))

(defmethod paste-aux ((os mac))
  (execute-paste '("pbpaste")))

;;;
(defclass unix (os)
  ((copy-command
    :initform nil
    :accessor unix-copy-command)
   (paste-command
    :initform nil
    :accessor unix-paste-command)))

(defun do-command (commands function)
  (dolist (command commands)
    (handler-case (funcall function command)
      (error ())
      (:no-error (&rest values)
        (return (apply #'values command values))))))

(defmethod copy-aux ((os unix) text)
  (if-let (command (unix-copy-command os))
    (execute-copy command text)
    (let ((command (do-command *unix-copy-commands*
                     (rcurry #'execute-copy text))))
      (setf (unix-copy-command os) command))))

(defmethod paste-aux ((os unix))
  (if-let (command (unix-paste-command os))
    (execute-paste command)
    (multiple-value-bind (command text)
        (do-command *unix-paste-commands*
          #'execute-paste)
      (setf (unix-paste-command os) command)
      text)))

;;;
(defclass wsl (os)
  ())

(defmethod copy-aux ((os wsl) text)
  (execute-copy '("clip.exe") text))

(defmethod paste-aux ((os wsl))
  (let ((text (execute-paste '("powershell.exe" "Get-Clipboard"))))
    (setf text (ppcre:regex-replace-all "\\r" text ""))
    (when (and (plusp (length text))
               (char= #\newline (char text (1- (length text)))))
      (setf text (subseq text 0 (1- (length text)))))
    text))

;;;
(defclass windows (os)
  ())

;;;
(defun get-os-name ()
  #+sbcl (declare (sb-ext:muffle-conditions sb-ext:compiler-note))
  (or #+darwin
      'mac
      #+unix
      (if (lem:wsl-p) 'wsl 'unix)
      'windows))

(defvar *os*)

(defun os ()
  (if (boundp '*os*)
      *os*
      (setf *os* (make-instance (get-os-name)))))

;;; OSC 52 clipboard fallback.
;;;
;;; On a headless ssh box there is no local clipboard tool at all. When none
;;; works (or when the CLIPBOARD-OSC52 editor variable selects it explicitly),
;;; emit an OSC 52 sequence so the outer terminal stores the text. The escape is
;;; written through the same tty channel term.lisp uses for other raw sequences,
;;; not through curses' buffered screen output. See SPEC.md, TF-2.

(defvar *osc52-truncation-warned-p* nil
  "Set once a copy has been truncated to fit OSC 52, so the message fires once.")

(defun in-tmux-p ()
  "Return T when running inside a tmux session."
  (let ((tmux (uiop:getenv "TMUX")))
    (and tmux (plusp (length tmux)))))

(defun copy-via-osc52 (text)
  "Place TEXT on the system clipboard by emitting an OSC 52 escape sequence.
Empty text is a no-op: an empty OSC 52 payload clears the terminal's clipboard,
so never emit one (which would silently wipe the user's clipboard over ssh)."
  (when (zerop (length text))
    (return-from copy-via-osc52 (values)))
  (multiple-value-bind (sequence truncated-p)
      (lem/common/osc52:encode-clipboard-sequence text :tmux (in-tmux-p))
    (lem-ncurses/term:write-terminal-string sequence)
    (when (and truncated-p (not *osc52-truncation-warned-p*))
      (setf *osc52-truncation-warned-p* t)
      (lem:message "Clipboard text too large for OSC 52; copied first ~D KB."
                   (floor lem/common/osc52:*max-payload-octets* 1024))))
  (values))

(defun try-local-copy (text)
  "Attempt to copy TEXT with an OS-native clipboard tool.
Return T on success, NIL when no local tool is available or all of them failed.
On :UNIX, COPY-AUX returns NIL when every candidate command failed; on the other
platforms a failure signals an error, which is treated the same way."
  (handler-case
      (if (typep (os) 'unix)
          (not (null (copy-aux (os) text)))
          (progn (copy-aux (os) text) t))
    (error () nil)))

(defun copy (text)
  (case (lem:variable-value 'lem:clipboard-osc52 :global)
    ((nil)
     (copy-aux (os) text))
    ((t)
     (copy-via-osc52 text))
    (otherwise                          ; :fallback (and any unexpected value)
     (unless (try-local-copy text)
       (copy-via-osc52 text))))
  (values))

(defun paste ()
  (paste-aux (os)))
