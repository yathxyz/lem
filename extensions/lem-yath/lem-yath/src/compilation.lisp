;;;; Emacs-style asynchronous compilation for SPC c c.

(in-package :lem-yath)

(require :sb-posix)

;; A source reload must first stop the process tree owned by the old closures.
(eval-when (:load-toplevel :execute)
  (when (fboundp 'compilation-cleanup-for-reload)
    (compilation-cleanup-for-reload)))

(defparameter *compilation-buffer-name* "*compilation*")
(defparameter *compilation-save-diff-buffer-name* "*compilation save diff*")

(defparameter *compilation-output-limit* (* 8 1024 1024)
  "Maximum raw output octets retained from one compilation process.")
(defparameter *compilation-save-diff-input-limit* (* 16 1024 1024)
  "Maximum file or live-buffer characters accepted by the save diff action.")
(defparameter *compilation-ansi-tail-limit* 4096
  "Maximum incomplete ANSI control sequence retained between process chunks.")
(defparameter *compilation-force-kill-delay* 1
  "Seconds between an interactive interrupt and a fail-safe SIGKILL.")
(defun compilation-find-runtime-path-program (name)
  "Resolve NAME from the wrapper's immutable runtime path only."
  (loop :for directory
          :in (uiop:split-string
               (or (uiop:getenv "LEM_YATH_RUNTIME_PATH") "")
               :separator (executable-path-separator))
        :when (plusp (length directory))
          :do (loop :for candidate-name :in (executable-candidate-names name)
                    :for candidate :=
                      (merge-pathnames
                       candidate-name
                       (uiop:ensure-directory-pathname directory))
                    :when (and (ignore-errors (probe-file candidate))
                               (not (uiop:directory-pathname-p candidate)))
                      :do (return-from compilation-find-runtime-path-program
                            candidate))))

(defun compilation-find-runtime-program (name)
  "Resolve NAME from the wrapper's immutable runtime path when available."
  (or (compilation-find-runtime-path-program name)
      (executable-find name)))

(defun compilation-pinned-program (variable)
  "Resolve VARIABLE as a pinned absolute program pathname, or NIL."
  (let* ((value (uiop:getenv variable))
         (candidate
           (and value
                (plusp (length value))
                (ignore-errors (pathname value)))))
    (and candidate
         (uiop:absolute-pathname-p candidate)
         (ignore-errors (probe-file candidate))
         (not (uiop:directory-pathname-p candidate))
         candidate)))

;; Trusted executables are cached on first use, before a selected project can
;; change PATH.  They must not be resolved at load time: a release image would
;; bake the build machine's lookups (or their absence) into the dumped values.
(defvar *compilation-bash-program* nil)
(defvar *compilation-nproc-program* nil)

#+os-windows
(defun compilation-windows-untrusted-bash-p (pathname)
  "Whether PATHNAME is one of the deceptive Windows bash.exe stubs.
The WindowsApps execution-alias directory and System32 both ship a
bash.exe that launches WSL (or, without a distribution, an error
dialog); neither can run a native Windows compilation."
  (flet ((normalized (pathname)
           (string-downcase (uiop:native-namestring pathname))))
    (let ((name (normalized pathname))
          (windir (uiop:getenv "SystemRoot")))
      (or (search "\\windowsapps\\" name)
          (and windir
               (plusp (length windir))
               (uiop:string-prefix-p
                (normalized (uiop:ensure-directory-pathname windir))
                name))))))

#+os-windows
(defun compilation-windows-bash-candidates ()
  "MSYS Bash locations derived from Git for Windows and MSYS2 installs.
The usr/bin binary is the real Bash; the bin/ launcher shim is tried
second.  A git.exe already trusted by PATH pins its own install root."
  (append
   (alexandria:when-let ((git (executable-find "git")))
     (unless (compilation-windows-untrusted-bash-p git)
       (let ((root (uiop:pathname-parent-directory-pathname
                    (uiop:pathname-directory-pathname git))))
         (list (merge-pathnames "usr/bin/bash.exe" root)
               (merge-pathnames "bin/bash.exe" root)))))
   (loop :for (variable subdirectory)
           :in '(("ProgramFiles" "Git/")
                 ("ProgramW6432" "Git/")
                 ("ProgramFiles(x86)" "Git/")
                 ("LOCALAPPDATA" "Programs/Git/"))
         :for base := (uiop:getenv variable)
         :when (and base (plusp (length base)))
           :append (let ((root (merge-pathnames
                                subdirectory
                                (uiop:ensure-directory-pathname base))))
                     (list (merge-pathnames "usr/bin/bash.exe" root)
                           (merge-pathnames "bin/bash.exe" root))))
   (list #p"c:/msys64/usr/bin/bash.exe"
         #p"c:/msys32/usr/bin/bash.exe")))

#+os-windows
(defun compilation-windows-find-bash ()
  "Locate a trusted MSYS Bash, never the WSL stubs on PATH."
  (flet ((usable-p (candidate)
           (and candidate
                (ignore-errors (probe-file candidate))
                (not (uiop:directory-pathname-p candidate))
                (not (compilation-windows-untrusted-bash-p candidate)))))
    (or (alexandria:when-let ((pinned (compilation-pinned-program
                                       "LEM_YATH_BASH")))
          (and (usable-p pinned) pinned))
        (alexandria:when-let ((runtime (compilation-find-runtime-path-program
                                        "bash")))
          (and (usable-p runtime) runtime))
        (find-if #'usable-p (compilation-windows-bash-candidates))
        (alexandria:when-let ((found (executable-find "bash")))
          (and (usable-p found) found)))))

(defun compilation-bash-program ()
  (or *compilation-bash-program*
      (setf *compilation-bash-program*
            #+os-windows (compilation-windows-find-bash)
            #-os-windows (compilation-find-runtime-program "bash"))))

(defun compilation-nproc-program ()
  (or *compilation-nproc-program*
      (setf *compilation-nproc-program*
            (compilation-find-runtime-program "nproc"))))

(defun compilation-ensure-supported ()
  "Fail early on hosts that lack a usable compilation backend.
POSIX hosts validate their process-group guardian at launch time.
Windows instead needs a trusted MSYS Bash before prompting is useful:
the bash.exe stubs in WindowsApps and System32 only launch WSL."
  #+os-windows
  (unless (compilation-bash-program)
    (editor-error
     "Compilation requires Git for Windows or MSYS2 Bash; none was found"))
  t)

(defvar *lem-yath-compilation-mode-keymap* (make-keymap))
(defvar *compilation-session* nil)
(defvar *compilation-default-command-cache* nil)
(defvar *compilation-attribute-cache* (make-hash-table :test #'equal))

(defstruct compilation-diagnostic
  pathname
  line
  column
  message
  output-line)

(defstruct compilation-session
  buffer
  origin-buffer
  origin-window
  command
  directory
  environment
  process
  pid
  managed-job
  (pending-output nil)
  output-event-p
  terminal-result
  terminal-delivered-p
  (output-octets 0)
  (output-limit *compilation-output-limit*)
  output-overflow-p
  output-error
  ;; Windows backend state: the Job Object HANDLE (a raw integer) that owns
  ;; the command tree, and the private launch script deleted at reap time.
  job
  script-pathname
  control-armed-p
  (control-lock (bt2:make-lock :name "lem-yath/compilation-control"))
  reader-thread
  (state :starting)
  interrupted-p
  interrupt-deadline
  (ansi-tail "")
  ansi-foreground
  ansi-background
  ansi-bold-p
  ansi-underline-p
  ansi-reverse-p
  (parse-tail "")
  (next-output-line 1)
  (diagnostics (make-array 0 :adjustable t :fill-pointer 0))
  (diagnostics-by-line (make-hash-table :test #'eql))
  current-diagnostic-index)

(define-major-mode lem-yath-compilation-mode nil
    (:name "Compilation"
     :keymap *lem-yath-compilation-mode-keymap*)
  (setf (buffer-read-only-p (current-buffer)) t
        (variable-value 'line-wrap :buffer (current-buffer)) nil
        (variable-value 'highlight-line :buffer (current-buffer)) t
        (variable-value 'lem/show-paren:enable :buffer (current-buffer)) nil))

;; Vi state maps precede ordinary major-mode maps in pinned Lem.  Compilation
;; keys must win over normal-state motions and operators.
(defmethod lem-vi-mode/core:mode-specific-keymaps
    ((mode lem-yath-compilation-mode))
  (list *lem-yath-compilation-mode-keymap*))

(defun compilation-live-buffer-p (buffer)
  (and buffer (not (deleted-buffer-p buffer))))

(defun compilation-session-owns-buffer-p (session)
  (let ((buffer (and session (compilation-session-buffer session))))
    (and (compilation-live-buffer-p buffer)
         (eq session (buffer-value buffer :lem-yath-compilation-session)))))

(defun compilation-process-alive-p (session)
  (and session
       #+linux
       (let ((job (compilation-session-managed-job session)))
         (and job (not (lem-toolkit/jobs:job-result job))))
       #-linux
       (and (compilation-session-process session)
            (compilation-control-armed-p session)
            (member (compilation-session-state session)
                    '(:starting :running :interrupting)))))

(defun compilation-number-of-processors ()
  "Return the affinity-aware processor count used by Emacs 31's default."
  (or (ignore-errors
        (let* ((program (compilation-nproc-program))
               (output (and program
                            (uiop:run-program (list (namestring program))
                                              :output :string
                                              :error-output :string
                                              :environment
                                              '("LC_ALL=C" "PATH="))))
               (count (and output
                           (parse-integer output :junk-allowed t))))
          (and count (plusp count) count)))
      #+os-windows
      (ignore-errors
        (let ((count (parse-integer
                      (or (uiop:getenv "NUMBER_OF_PROCESSORS") "")
                      :junk-allowed t)))
          (and count (plusp count) count)))
      1))

(defun compilation-default-command ()
  "Return the pinned Emacs 31 `compile-command' default."
  (or *compilation-default-command-cache*
      (setf *compilation-default-command-cache*
            (format nil "make -k -j~d "
                    (ceiling (* 2 (compilation-number-of-processors)) 3)))))

(defun compilation-command-for-buffer (buffer)
  (or (buffer-value buffer 'lem-yath-compile-command)
      (compilation-default-command)))

(defun (setf compilation-command-for-buffer) (command buffer)
  (setf (buffer-value buffer 'lem-yath-compile-command) command))

(defun compilation-directory-for-buffer (buffer)
  (uiop:ensure-directory-pathname
   (pathname (or (ignore-errors (buffer-directory buffer))
                 (uiop:getcwd)))))

(defun compilation-time-string ()
  (multiple-value-bind (second minute hour day month year)
      (decode-universal-time (get-universal-time))
    (format nil "~4,'0d-~2,'0d-~2,'0d ~2,'0d:~2,'0d:~2,'0d"
            year month day hour minute second)))

;;; Save-before-compile ------------------------------------------------------

(defun compilation-read-file-bounded (pathname)
  (if (not (probe-file pathname))
      ""
      (with-open-file (stream pathname
                              :direction :input
                              :external-format :utf-8)
        (let ((chunk (make-string 8192))
              (count 0)
              (output (make-string-output-stream)))
          (loop :for length := (read-sequence chunk stream)
                :until (zerop length)
                :do (incf count length)
                    (when (> count *compilation-save-diff-input-limit*)
                      (editor-error
                       "Save diff input exceeds ~d characters"
                       *compilation-save-diff-input-limit*))
                    (write-sequence chunk output :end length))
          (get-output-stream-string output)))))

(defun compilation-buffer-text-bounded (buffer)
  (let ((text (points-to-string (buffer-start-point buffer)
                                (buffer-end-point buffer))))
    (when (> (length text) *compilation-save-diff-input-limit*)
      (editor-error "Save diff input exceeds ~d characters"
                    *compilation-save-diff-input-limit*))
    text))

(defun compilation-save-diff-text (buffer)
  (let* ((filename (buffer-filename buffer))
         (label (uiop:native-namestring filename)))
    (vundo-unified-diff
     (compilation-read-file-bounded filename)
     (compilation-buffer-text-bounded buffer)
     label
     (format nil "~a (buffer)" label))))

(defun compilation-delete-save-diff-buffer (buffer)
  (when (compilation-live-buffer-p buffer)
    (ignore-errors (delete-buffer buffer))))

(defun compilation-show-save-diff (source-buffer)
  (let ((buffer (make-buffer *compilation-save-diff-buffer-name*
                             :enable-undo-p nil)))
    (buffer-disable-undo buffer)
    (with-buffer-read-only buffer nil
      (erase-buffer buffer)
      (insert-string (buffer-start-point buffer)
                     (compilation-save-diff-text source-buffer))
      (buffer-start (buffer-point buffer)))
    (setf (buffer-read-only-p buffer) t)
    (pop-to-buffer buffer)
    buffer))

(defun compilation-save-query (buffer)
  "Query for BUFFER and return :SAVE, :SKIP, :SAVE-ALL, :DONE, or :CANCEL."
  (let ((diff-buffer nil))
    (unwind-protect
         (loop
           :for answer :=
             (char-downcase
              (prompt-for-character
               (format nil
                       "Save file ~a? [y/n/!/./q/d] "
                       (buffer-filename buffer))))
           :do
              (case answer
                (#\y (return :save))
                (#\n (return :skip))
                (#\! (return :save-all))
                (#\. (return :done))
                (#\q (return :cancel))
                (#\d
                 (compilation-delete-save-diff-buffer diff-buffer)
                 (setf diff-buffer
                       (handler-case
                           (compilation-show-save-diff buffer)
                         (error (condition)
                           (message "Cannot show save diff: ~a" condition)
                           nil))))
                (otherwise
                 (message "Choose y, n, !, ., q, or d"))))
      (compilation-delete-save-diff-buffer diff-buffer))))

(defun compilation-modified-file-buffers ()
  (remove-if-not
   (lambda (buffer)
     (and (compilation-live-buffer-p buffer)
          (buffer-filename buffer)
          (buffer-modified-p buffer)))
   (buffer-list)))

(defun compilation-save-buffer (buffer)
  (save-buffer buffer)
  t)

(defun compilation-save-before-start (origin-buffer origin-window)
  "Mirror `save-some-buffers', including the configured `d' diff action."
  (let ((buffers (compilation-modified-file-buffers)))
    (unwind-protect
         (loop :for rest :on buffers
               :for buffer := (first rest)
               :do
                  (switch-to-buffer buffer nil)
                  (case (compilation-save-query buffer)
                    (:save (compilation-save-buffer buffer))
                    (:skip)
                    (:save-all
                     (dolist (remaining rest)
                       (compilation-save-buffer remaining))
                     (return t))
                    (:done
                     (compilation-save-buffer buffer)
                     (return t))
                    (:cancel (return nil)))
               :finally (return t))
      (when (and origin-window (not (deleted-window-p origin-window)))
        (setf (current-window) origin-window))
      (when (compilation-live-buffer-p origin-buffer)
        (switch-to-buffer origin-buffer nil)))))

;;; ANSI SGR decoding -------------------------------------------------------

(defparameter *compilation-basic-ansi-colors*
  #("#000000" "#cd0000" "#00cd00" "#cdcd00"
    "#0000ee" "#cd00cd" "#00cdcd" "#e5e5e5"
    "#7f7f7f" "#ff0000" "#00ff00" "#ffff00"
    "#5c5cff" "#ff00ff" "#00ffff" "#ffffff"))

(defun compilation-xterm-color (index)
  (cond
    ((not (and (integerp index) (<= 0 index 255))) nil)
    ((< index 16) (aref *compilation-basic-ansi-colors* index))
    ((< index 232)
     (let* ((offset (- index 16))
            (red (floor offset 36))
            (green (floor (mod offset 36) 6))
            (blue (mod offset 6))
            (level (lambda (component)
                     (if (zerop component) 0 (+ 55 (* component 40))))))
       (format nil "#~2,'0x~2,'0x~2,'0x"
               (funcall level red)
               (funcall level green)
               (funcall level blue))))
    (t
     (let ((level (+ 8 (* 10 (- index 232)))))
       (format nil "#~2,'0x~2,'0x~2,'0x" level level level)))))

(defun compilation-rgb-color (red green blue)
  (when (every (lambda (value)
                 (and (integerp value) (<= 0 value 255)))
               (list red green blue))
    (format nil "#~2,'0x~2,'0x~2,'0x" red green blue)))

(defun compilation-ansi-attribute (session)
  (let ((foreground (compilation-session-ansi-foreground session))
        (background (compilation-session-ansi-background session))
        (bold (compilation-session-ansi-bold-p session))
        (underline (compilation-session-ansi-underline-p session))
        (reverse (compilation-session-ansi-reverse-p session)))
    (when (or foreground background bold underline reverse)
      (let ((key (list foreground background bold underline reverse)))
        (or (gethash key *compilation-attribute-cache*)
            (progn
              (when (> (hash-table-count *compilation-attribute-cache*) 1024)
                (clrhash *compilation-attribute-cache*))
              (setf (gethash key *compilation-attribute-cache*)
                    (make-attribute :foreground foreground
                                    :background background
                                    :bold bold
                                    :underline underline
                                    :reverse reverse))))))))

(defun compilation-parse-sgr-number (string)
  (if (zerop (length string))
      0
      (handler-case (parse-integer string)
        (error () nil))))

(defun compilation-sgr-values (parameters)
  (mapcar #'compilation-parse-sgr-number
          (uiop:split-string parameters :separator ";")))

(defun compilation-apply-extended-color (session target values index)
  "Apply a 38/48 color at INDEX.  Return the next unconsumed index."
  (let ((kind (nth (1+ index) values)))
    (labels ((set-color (color)
               (when color
                 (if (eq target :foreground)
                     (setf (compilation-session-ansi-foreground session) color)
                     (setf (compilation-session-ansi-background session) color)))))
      (cond
        ((and (eql kind 5) (nth (+ index 2) values))
         (set-color (compilation-xterm-color (nth (+ index 2) values)))
         (+ index 3))
        ((and (eql kind 2)
              (nth (+ index 2) values)
              (nth (+ index 3) values)
              (nth (+ index 4) values))
         (set-color
          (compilation-rgb-color (nth (+ index 2) values)
                                 (nth (+ index 3) values)
                                 (nth (+ index 4) values)))
         (+ index 5))
        (t (1+ index))))))

(defun compilation-apply-sgr (session parameters)
  (let ((values (if (zerop (length parameters))
                    '(0)
                    (compilation-sgr-values parameters))))
    (loop :with index = 0
          :while (< index (length values))
          :for value := (nth index values)
          :do
             (cond
               ((null value) (incf index))
               ((zerop value)
                (setf (compilation-session-ansi-foreground session) nil
                      (compilation-session-ansi-background session) nil
                      (compilation-session-ansi-bold-p session) nil
                      (compilation-session-ansi-underline-p session) nil
                      (compilation-session-ansi-reverse-p session) nil)
                (incf index))
               ((eql value 1)
                (setf (compilation-session-ansi-bold-p session) t)
                (incf index))
               ((eql value 4)
                (setf (compilation-session-ansi-underline-p session) t)
                (incf index))
               ((eql value 7)
                (setf (compilation-session-ansi-reverse-p session) t)
                (incf index))
               ((eql value 22)
                (setf (compilation-session-ansi-bold-p session) nil)
                (incf index))
               ((eql value 24)
                (setf (compilation-session-ansi-underline-p session) nil)
                (incf index))
               ((eql value 27)
                (setf (compilation-session-ansi-reverse-p session) nil)
                (incf index))
               ((eql value 39)
                (setf (compilation-session-ansi-foreground session) nil)
                (incf index))
               ((eql value 49)
                (setf (compilation-session-ansi-background session) nil)
                (incf index))
               ((<= 30 value 37)
                (setf (compilation-session-ansi-foreground session)
                      (compilation-xterm-color (- value 30)))
                (incf index))
               ((<= 90 value 97)
                (setf (compilation-session-ansi-foreground session)
                      (compilation-xterm-color (+ 8 (- value 90))))
                (incf index))
               ((<= 40 value 47)
                (setf (compilation-session-ansi-background session)
                      (compilation-xterm-color (- value 40)))
                (incf index))
               ((<= 100 value 107)
                (setf (compilation-session-ansi-background session)
                      (compilation-xterm-color (+ 8 (- value 100))))
                (incf index))
               ((eql value 38)
                (setf index
                      (compilation-apply-extended-color
                       session :foreground values index)))
               ((eql value 48)
                (setf index
                      (compilation-apply-extended-color
                       session :background values index)))
               (t (incf index))))))

(defun compilation-ansi-final-character-p (character)
  (let ((code (char-code character)))
    (<= #x40 code #x7e)))

(defun compilation-ansi-decode (session chunk)
  "Return styled visible segments and plain text for possibly split CHUNK."
  (let* ((source (concatenate 'string
                              (compilation-session-ansi-tail session)
                              chunk))
         (length (length source))
         (index 0)
         (segments nil)
         (plain (make-string-output-stream))
         (incomplete-start nil))
    (setf (compilation-session-ansi-tail session) "")
    (labels ((emit (start end)
               (when (< start end)
                 (let ((text (subseq source start end)))
                   (push (cons text (compilation-ansi-attribute session))
                         segments)
                   (write-string text plain))))
             (mark-incomplete (start)
               (setf incomplete-start start
                     index length)))
      (loop :while (< index length)
            :do
               (let ((escape (position (code-char 27) source :start index)))
                 (if (null escape)
                     (progn (emit index length) (setf index length))
                     (progn
                       (emit index escape)
                       (cond
                         ((>= (1+ escape) length)
                          (mark-incomplete escape))
                         ((char= (char source (1+ escape)) #\[)
                          (let ((final
                                  (loop :for scan-index :from (+ escape 2)
                                        :below length
                                        :when (compilation-ansi-final-character-p
                                               (char source scan-index))
                                          :return scan-index)))
                            (if (null final)
                                (mark-incomplete escape)
                                (progn
                                  (when (char= (char source final) #\m)
                                    (compilation-apply-sgr
                                     session
                                     (subseq source (+ escape 2) final)))
                                  ;; Non-SGR CSI controls are deliberately
                                  ;; consumed instead of rendered as garbage.
                                  (setf index (1+ final))))))
                         ((char= (char source (1+ escape)) #\])
                          (let ((terminator
                                  (loop :for control-index :from (+ escape 2)
                                        :below length
                                        :when (or
                                                (char= (char source control-index)
                                                       (code-char 7))
                                                (and
                                                 (char= (char source control-index)
                                                        (code-char 27))
                                                 (< (1+ control-index) length)
                                                 (char= (char source (1+ control-index))
                                                        #\\)))
                                          :return control-index)))
                            (if (null terminator)
                                (mark-incomplete escape)
                                (setf index
                                      (if (char= (char source terminator)
                                                 (code-char 27))
                                          (+ terminator 2)
                                          (1+ terminator))))))
                         (t
                          ;; Consume a two-byte escape sequence.
                          (setf index (+ escape 2))))))))
      (when incomplete-start
        (let ((tail (subseq source incomplete-start)))
          (if (> (length tail) *compilation-ansi-tail-limit*)
              (progn
                (push (cons "�" nil) segments)
                (write-string "�" plain))
              (setf (compilation-session-ansi-tail session) tail))))
      (values (nreverse segments) (get-output-stream-string plain)))))

;;; Diagnostics -------------------------------------------------------------

(defun compilation-parse-positive-integer (string &optional default)
  (or (ignore-errors
        (let ((value (and string (parse-integer string))))
          (and value (plusp value) value)))
      default))

(defun compilation-location-match (line)
  "Return PATH, LINE, COLUMN, MESSAGE fields encoded as a list."
  (or
   (cl-ppcre:register-groups-bind (path row column)
       ("^Meson encountered an error in file (.+), line ([0-9]+), column ([0-9]+):"
        line)
     (list path row column line))
   (cl-ppcre:register-groups-bind (path row)
       ("^[ \t]*File \"([^\"]+)\", line ([0-9]+)(?:,.*)?$" line)
     (list path row nil line))
   (cl-ppcre:register-groups-bind (path row column)
       ("^[ \t]*-->[ \t]+(.+?):([0-9]+):([0-9]+)[ \t]*$" line)
     (list path row column line))
   (cl-ppcre:register-groups-bind (path row column message)
       ("^[ \t]*at[ \t]+(.+?):([0-9]+):([0-9]+):?[ \t]*(.*)$" line)
     (list path row column message))
   (cl-ppcre:register-groups-bind (path row column message)
       ("^.*?[ \t]at[ \t]+(.+?):([0-9]+):([0-9]+):?[ \t]*(.*)$" line)
     (list path row column message))
   (cl-ppcre:register-groups-bind (path row column message)
       ("^(?:vet:[ \t]+)?(.+?):([0-9]+)(?::([0-9]+))?:[ \t]*(.*)$"
        line)
     (list path row column message))))

(defun compilation-control-character-p (character)
  (and (< (char-code character) 32)
       (not (member character '(#\Tab)))))

(defun compilation-resolve-diagnostic-path (directory reported)
  (let ((reported (string-trim '(#\Space #\Tab #\" #\') reported)))
    (when (and (plusp (length reported))
               (<= (length reported) 4096)
               (not (search "://" reported))
               (not (member reported
                            '("<stdin>" "<standard input>" "stdin")
                            :test #'string-equal))
               (notany #'compilation-control-character-p reported))
      (handler-case
          (let* ((pathname (pathname reported))
                 (absolute
                   (if (uiop:absolute-pathname-p pathname)
                       pathname
                       (merge-pathnames pathname directory))))
            (unless (wild-pathname-p absolute)
              absolute))
        (error () nil)))))

(defun compilation-clean-diagnostic-message (message raw)
  (let ((clean
          (string-trim '(#\Space #\Tab #\Return)
                       (or message ""))))
    (if (plusp (length clean)) clean raw)))

(defun compilation-parse-diagnostic (session line output-line)
  (alexandria:when-let ((fields (compilation-location-match line)))
    (destructuring-bind (reported row column message) fields
      (let ((pathname
              (compilation-resolve-diagnostic-path
               (compilation-session-directory session) reported))
            (row (compilation-parse-positive-integer row))
            (column (compilation-parse-positive-integer column 1)))
        (when (and pathname row)
          (make-compilation-diagnostic
           :pathname pathname
           :line row
           :column column
           :message (compilation-clean-diagnostic-message message line)
           :output-line output-line))))))

(defun compilation-mark-diagnostic-line (session diagnostic index)
  (let ((buffer (compilation-session-buffer session)))
    (when (compilation-live-buffer-p buffer)
      (with-point ((start (buffer-start-point buffer))
                   (end (buffer-start-point buffer)))
        (move-to-line start (compilation-diagnostic-output-line diagnostic))
        (move-point end start)
        (line-end end)
        (unless (end-buffer-p end)
          (character-offset end 1))
        (put-text-property start end :lem-yath-compilation-diagnostic-index
                           index)))))

(defun compilation-register-output-line (session line output-line)
  (alexandria:when-let
      ((diagnostic (compilation-parse-diagnostic session line output-line)))
    (let* ((diagnostics (compilation-session-diagnostics session))
           (index (fill-pointer diagnostics)))
      (vector-push-extend diagnostic diagnostics)
      (setf (gethash output-line
                     (compilation-session-diagnostics-by-line session))
            diagnostic)
      (compilation-mark-diagnostic-line session diagnostic index))))

(defun compilation-consume-plain-output (session text)
  (let* ((source (concatenate 'string
                              (compilation-session-parse-tail session)
                              text))
         (start 0)
         (line-number (compilation-session-next-output-line session)))
    (loop :for newline := (position #\Newline source :start start)
          :while newline
          :for line := (string-right-trim
                        '(#\Return) (subseq source start newline))
          :do (compilation-register-output-line session line line-number)
              (incf line-number)
              (setf start (1+ newline)))
    (setf (compilation-session-parse-tail session) (subseq source start)
          (compilation-session-next-output-line session) line-number)))

;;; Buffer insertion --------------------------------------------------------

(defun compilation-append-styled-output (session segments plain)
  (when (compilation-session-owns-buffer-p session)
    (let* ((buffer (compilation-session-buffer session))
           (follow-p (point= (buffer-point buffer)
                             (buffer-end-point buffer))))
      (with-buffer-read-only buffer nil
        (let ((point (buffer-end-point buffer)))
          (dolist (segment segments)
            (destructuring-bind (text . attribute) segment
              (with-point ((start point :right-inserting))
                (insert-string point text)
                (when attribute
                  (put-text-property start point :attribute attribute)))))))
      (compilation-consume-plain-output session plain)
      (when follow-p
        (buffer-end (buffer-point buffer)))
      (buffer-unmark buffer)
      (redraw-display))))

(defun compilation-append-plain (session text)
  (compilation-append-styled-output
   session (list (cons text nil)) ""))

(defun compilation-deliver-chunk (session chunk)
  (when (compilation-session-owns-buffer-p session)
    (multiple-value-bind (segments plain)
        (compilation-ansi-decode session chunk)
      (compilation-append-styled-output session segments plain))))

(defun compilation-finish-pending-line (session)
  (when (plusp (length (compilation-session-parse-tail session)))
    (compilation-consume-plain-output session (string #\Newline))))

;;; Process lifecycle -------------------------------------------------------

(defun compilation-control-armed-p (session)
  (and session
       (bt2:with-lock-held ((compilation-session-control-lock session))
         (compilation-session-control-armed-p session))))

(defun compilation-arm-control (session)
  (bt2:with-lock-held ((compilation-session-control-lock session))
    (setf (compilation-session-control-armed-p session) t)))

(defun compilation-disarm-control (session)
  (when session
    (bt2:with-lock-held ((compilation-session-control-lock session))
      (setf (compilation-session-control-armed-p session) nil))))

(defun compilation-force-stop (session)
  #+os-windows (compilation-windows-force-stop session)
  #+linux
  (when (compilation-session-managed-job session)
    (lem-toolkit/jobs:cancel-job (compilation-session-managed-job session))))

(defun compilation-stop-process-group-as (session state)
  #+os-windows (compilation-windows-stop-tree-as session state)
  #+linux
  (progn
    (setf (compilation-session-state session) state)
    (compilation-force-stop session)))

(defun compilation-request-interrupt (session)
  "Request immediate cancellation through the live job owner."
  #+os-windows (compilation-windows-request-interrupt session)
  #+linux
  (when (compilation-process-alive-p session)
    (setf (compilation-session-interrupted-p session) t
          (compilation-session-state session) :interrupting)
    (compilation-force-stop session)
    t))

#+os-windows
(defun compilation-reap-process (session)
  "Wait for SESSION's command owner, close its streams, and clear OS handles."
  (let ((process (compilation-session-process session))
        (exit-code nil))
    (when process
      (setf exit-code (ignore-errors (uiop:wait-process process)))
      (ignore-errors (uiop:close-streams process)))
    (compilation-disarm-control session)
    #+os-windows
    (compilation-windows-cleanup-session-resources session)
    (setf (compilation-session-process session) nil
          (compilation-session-pid session) nil)
    exit-code))

(defun compilation-detach-session (session state)
  (when session
    ;; A result buffer is a view. The manager retains the job and its result.
    (unless (eq state :buffer-killed)
      (compilation-stop-process-group-as session state)
      #+os-windows
      (progn
        (when (compilation-session-reader-thread session)
          (bt2:join-thread (compilation-session-reader-thread session)))
        (when (compilation-session-process session)
          (compilation-reap-process session)))
      (when (eq *compilation-session* session)
        (setf *compilation-session* nil)))
    (when (compilation-session-owns-buffer-p session)
      (setf (buffer-value (compilation-session-buffer session)
                          :lem-yath-compilation-session) nil))
    (when (eq *lem-yath-next-error-source* :compilation)
      (setf *lem-yath-next-error-source* :diagnostic))))

(defun compilation-queue-event (function)
  (ignore-errors (send-event function)))

(defun compilation-read-live-octets (stream buffer)
  "Drain one available octet burst; return its length and whether EOF was read."
  (let ((length 0))
    (loop :while (< length (length buffer))
          :while (listen stream)
          :for octet := (read-byte stream nil :eof)
          :do
             (when (eq octet :eof)
               (return-from compilation-read-live-octets
                 (values length t)))
             (setf (aref buffer length) octet)
             (incf length))
    (values length nil)))

(defun compilation-output-burst-drained-p (octet-count buffer)
  "Return true when the currently available output did not fill BUFFER."
  (< octet-count (length buffer)))

#+os-windows
(defun compilation-write-guardian-line (session line)
  (let ((stream (uiop:process-info-input
                 (compilation-session-process session))))
    (write-sequence (babel:string-to-octets
                     (format nil "~a~%" line)
                     :encoding :ascii)
                    stream)
    (finish-output stream)))

(defun compilation-utf8-continuation-p (octet minimum maximum)
  (and (<= minimum octet) (<= octet maximum)))

(defun compilation-utf8-complete-prefix-length (octets)
  "Validate OCTETS as strict UTF-8 and return the complete prefix length."
  (let ((length (length octets))
        (index 0))
    (block scan
      (loop :while (< index length)
            :for lead := (aref octets index)
            :do
               (cond
                 ((<= lead #x7f)
                  (incf index))
                 (t
                  (multiple-value-bind (width second-minimum second-maximum)
                      (cond
                        ((<= #xc2 lead #xdf)
                         (values 2 #x80 #xbf))
                        ((= lead #xe0)
                         (values 3 #xa0 #xbf))
                        ((<= #xe1 lead #xec)
                         (values 3 #x80 #xbf))
                        ((= lead #xed)
                         (values 3 #x80 #x9f))
                        ((<= #xee lead #xef)
                         (values 3 #x80 #xbf))
                        ((= lead #xf0)
                         (values 4 #x90 #xbf))
                        ((<= #xf1 lead #xf3)
                         (values 4 #x80 #xbf))
                        ((= lead #xf4)
                         (values 4 #x80 #x8f))
                        (t
                         (error "Invalid UTF-8 lead octet 0x~2,'0x"
                                lead)))
                    (let ((available (min width (- length index))))
                      (loop :for offset :from 1 :below available
                            :for octet := (aref octets (+ index offset))
                            :for minimum := (if (= offset 1)
                                                second-minimum
                                                #x80)
                            :for maximum := (if (= offset 1)
                                                second-maximum
                                                #xbf)
                            :unless (compilation-utf8-continuation-p
                                     octet minimum maximum)
                              :do (error
                                   "Invalid UTF-8 continuation octet 0x~2,'0x"
                                   octet))
                      (when (< available width)
                        (return-from scan index))
                      (incf index width)))))
            :finally (return-from scan length)))))

(defun compilation-decode-utf8-prefix (tail buffer length)
  "Strictly decode TAIL plus BUFFER[0,LENGTH), retaining an incomplete suffix."
  (let* ((tail-length (length tail))
         (octets
           (make-array (+ tail-length length)
                       :element-type '(unsigned-byte 8))))
    (replace octets tail)
    (replace octets buffer :start1 tail-length :end2 length)
    (let ((complete (compilation-utf8-complete-prefix-length octets)))
      (values
       (if (zerop complete)
           ""
           (babel:octets-to-string octets
                                   :end complete
                                   :encoding :utf-8
                                   :errorp t))
       (subseq octets complete)))))

(defun compilation-interrupt-deadline-reached-p (session)
  (let ((deadline (compilation-session-interrupt-deadline session)))
    (and deadline
         (>= (get-internal-real-time) deadline))))

;;; Windows backend ----------------------------------------------------------
;;;
;;; Windows has no fork, setpgid, or killpg, so the POSIX guardian cannot
;;; run there.  This backend launches the trusted MSYS Bash directly and
;;; anchors tree containment in a Job Object instead of a process group:
;;;
;;;   - the command never appears in any argv: it lives in a private launch
;;;     script whose first line gates execution on Lem's START write;
;;;   - Lem assigns Bash to a kill-on-close Job before sending START, so no
;;;     part of the command can ever run outside the Job;
;;;   - KILL is TerminateJobObject over the whole tree, and an exiting or
;;;     crashed editor kills the tree when its last Job handle closes;
;;;   - normal completion clears kill-on-close first, mirroring the POSIX
;;;     guardian's RELEASE so intentional daemons may outlive the session;
;;;   - interrupt is best effort: an MSYS `kill -INT` toward Bash's emulated
;;;     tree, with the usual grace deadline escalating to the Job kill.

#+os-windows
(progn
  (defconstant +compilation-win32-job-extended-limit-information+ 9
    "The JobObjectExtendedLimitInformation information class.")
  (defconstant +compilation-win32-job-limit-kill-on-job-close+ #x2000
    "JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE.")
  (defconstant +compilation-win32-job-limit-information-size+ 144
    "sizeof(JOBOBJECT_EXTENDED_LIMIT_INFORMATION) on x86-64.")
  (defconstant +compilation-win32-job-limit-flags-offset+ 16
    "Byte offset of LimitFlags inside the basic limit information.")
  (defconstant +compilation-win32-process-adopt-access+ #x0101
    "PROCESS_SET_QUOTA | PROCESS_TERMINATE, as Job assignment requires.")
  (defconstant +compilation-win32-kill-exit-code+ 137
    "The exit status the POSIX backend reports for a SIGKILLed command.")

  (sb-alien:define-alien-routine ("CreateJobObjectW"
                                  %compilation-win32-create-job-object)
      sb-alien:unsigned-long-long
    (security-attributes sb-alien:unsigned-long-long)
    (name sb-alien:unsigned-long-long))

  (sb-alien:define-alien-routine ("SetInformationJobObject"
                                  %compilation-win32-set-information-job-object)
      sb-alien:int
    (job sb-alien:unsigned-long-long)
    (information-class sb-alien:int)
    (information sb-alien:unsigned-long-long)
    (information-length sb-alien:unsigned-int))

  (sb-alien:define-alien-routine ("AssignProcessToJobObject"
                                  %compilation-win32-assign-process-to-job-object)
      sb-alien:int
    (job sb-alien:unsigned-long-long)
    (process sb-alien:unsigned-long-long))

  (sb-alien:define-alien-routine ("TerminateJobObject"
                                  %compilation-win32-terminate-job-object)
      sb-alien:int
    (job sb-alien:unsigned-long-long)
    (exit-code sb-alien:unsigned-int))

  (sb-alien:define-alien-routine ("OpenProcess"
                                  %compilation-win32-open-process)
      sb-alien:unsigned-long-long
    (desired-access sb-alien:unsigned-int)
    (inherit-handle sb-alien:int)
    (process-id sb-alien:unsigned-int))

  (sb-alien:define-alien-routine ("TerminateProcess"
                                  %compilation-win32-terminate-process)
      sb-alien:int
    (process sb-alien:unsigned-long-long)
    (exit-code sb-alien:unsigned-int))

  (sb-alien:define-alien-routine ("CloseHandle"
                                  %compilation-win32-close-handle)
      sb-alien:int
    (handle sb-alien:unsigned-long-long)))

#+os-windows
(defun compilation-windows-set-job-limit-flags (job flags)
  "Install FLAGS as JOB's only basic limit; return whether it succeeded."
  (sb-alien:with-alien ((information (sb-alien:array sb-alien:unsigned-char
                                                     144)))
    (dotimes (index +compilation-win32-job-limit-information-size+)
      (setf (sb-alien:deref information index) 0))
    (dotimes (index 4)
      (setf (sb-alien:deref information
                           (+ +compilation-win32-job-limit-flags-offset+
                              index))
            (ldb (byte 8 (* 8 index)) flags)))
    (not (zerop
          (%compilation-win32-set-information-job-object
           job
           +compilation-win32-job-extended-limit-information+
           (sb-sys:sap-int (sb-alien:alien-sap information))
           +compilation-win32-job-limit-information-size+)))))

#+os-windows
(defun compilation-windows-kill-job-locked (session)
  "Terminate SESSION's Job tree and disarm; the control lock must be held."
  (let ((job (compilation-session-job session)))
    (when (and job
               (not (zerop job))
               (compilation-session-control-armed-p session))
      (ignore-errors
        (%compilation-win32-terminate-job-object
         job +compilation-win32-kill-exit-code+))))
  (setf (compilation-session-control-armed-p session) nil))

#+os-windows
(defun compilation-windows-force-stop (session)
  "Kill SESSION's whole Job tree and disarm atomically."
  (when session
    (bt2:with-lock-held ((compilation-session-control-lock session))
      (compilation-windows-kill-job-locked session))))

#+os-windows
(defun compilation-windows-stop-tree-as (session state)
  "Set terminal STATE, kill the whole Job tree, and disarm atomically."
  (bt2:with-lock-held ((compilation-session-control-lock session))
    (setf (compilation-session-state session) state)
    (compilation-windows-kill-job-locked session)))

#+os-windows
(defun compilation-windows-send-best-effort-interrupt (session)
  "Ask a sibling MSYS process to deliver SIGINT toward Bash's tree.
Windows has no console-free equivalent of killpg(SIGINT).  MSYS's kill
reaches only MSYS descendants and native build tools ignore it entirely,
so the grace deadline still escalates to the Job kill either way."
  (ignore-errors
    (let ((pid (compilation-session-pid session))
          (bash (compilation-bash-program)))
      (when (and (integerp pid) (plusp pid) bash)
        (let ((process
                (uiop:launch-program
                 (list (namestring bash) "--noprofile" "--norc" "-c"
                       (format nil
                               "kill -INT -- -~d 2>/dev/null || kill -INT ~d"
                               pid pid))
                 :input nil
                 :output nil
                 :error-output nil)))
          (bt2:make-thread
           (lambda ()
             (ignore-errors (uiop:wait-process process))
             (ignore-errors (uiop:close-streams process)))
           :name "lem-yath/compilation-interrupt"))))))

#+os-windows
(defun compilation-windows-request-interrupt (session)
  "Atomically arm the grace deadline and send the best-effort SIGINT."
  (bt2:with-lock-held ((compilation-session-control-lock session))
    (when (compilation-session-control-armed-p session)
      (setf (compilation-session-interrupted-p session) t
            (compilation-session-state session) :interrupting
            (compilation-session-interrupt-deadline session)
            (or (compilation-session-interrupt-deadline session)
                (+ (get-internal-real-time)
                   (round (* *compilation-force-kill-delay*
                             internal-time-units-per-second)))))
      (compilation-windows-send-best-effort-interrupt session)
      t)))

#+os-windows
(defun compilation-windows-release-job (session)
  "Mirror the guardian's RELEASE: drop kill-on-close on normal completion
so intentional daemons survive the Job handle closing at reap time."
  (bt2:with-lock-held ((compilation-session-control-lock session))
    (let ((job (compilation-session-job session)))
      (when (and (compilation-session-control-armed-p session)
                 (eq (compilation-session-state session) :running)
                 (not (compilation-session-interrupted-p session))
                 job
                 (not (zerop job)))
        (setf (compilation-session-state session) :finalizing
              (compilation-session-control-armed-p session) nil)
        (ignore-errors
          (compilation-windows-set-job-limit-flags job 0))
        t))))

#+os-windows
(defun compilation-windows-cleanup-session-resources (session)
  "Close the Job handle and delete the private launch script; idempotent."
  (bt2:with-lock-held ((compilation-session-control-lock session))
    (let ((job (compilation-session-job session)))
      (when (and job (not (zerop job)))
        (ignore-errors (%compilation-win32-close-handle job)))
      (setf (compilation-session-job session) nil))
    (let ((script (compilation-session-script-pathname session)))
      (when script
        (ignore-errors (delete-file script))
        (setf (compilation-session-script-pathname session) nil)))))

#+os-windows
(defun compilation-windows-restrict-file-acl (pathname)
  "Best-effort: replace PATHNAME's inherited ACEs with a user-only grant.
%TEMP% already inherits a user-private ACL, so failure here (redirected
temp, unusual SIDs, missing icacls) must not block compilation."
  (ignore-errors
    (let* ((system-root (uiop:getenv "SystemRoot"))
           (icacls (and system-root
                        (plusp (length system-root))
                        (probe-file
                         (merge-pathnames
                          "System32/icacls.exe"
                          (uiop:ensure-directory-pathname system-root)))))
           (user (uiop:getenv "USERNAME")))
      (when (and icacls user (plusp (length user)))
        (uiop:run-program
         (list (namestring icacls)
               (uiop:native-namestring pathname)
               "/inheritance:r"
               "/grant:r"
               (format nil "~a:F" user))
         :ignore-error-status t
         :input nil
         :output nil
         :error-output nil)))))

#+os-windows
(defun compilation-windows-script-octets (command)
  "The private launch script: a START gate, then COMMAND with null stdin.
Bash may not execute any part of COMMAND until Lem has assigned it to
the session's Job Object and written the gate line to its stdin."
  (when (find (code-char 0) command)
    (error "Compilation command contains NUL"))
  ;; One physical line: a multi-line ~-continued control string breaks
  ;; under a CRLF checkout, where ~Return is an invalid format directive.
  (babel:string-to-octets
   (format nil
           "read -r lem_yath_start_gate || exit 125~%unset lem_yath_start_gate~%exec </dev/null~%~a~%"
           command)
   :encoding :utf-8
   :errorp t))

#+os-windows
(defun compilation-windows-create-script (command)
  "Write COMMAND to a fresh private script file and return its pathname.
The command therefore never appears in any process's argv.  Exclusive
creation defeats name squatting, and the ACL is tightened before any
command text lands in the file."
  (let ((octets (compilation-windows-script-octets command))
        (directory (uiop:temporary-directory)))
    (loop :for attempt :from 0 :below 128
          :for pathname
            := (merge-pathnames
                (format nil "lem-yath-compile-~d-~d-~d.sh"
                        (get-universal-time)
                        (get-internal-real-time)
                        attempt)
                directory)
          :for stream := (open pathname
                               :direction :output
                               :element-type '(unsigned-byte 8)
                               :if-exists nil
                               :if-does-not-exist :create)
          :when stream
            :do (unwind-protect
                     (progn
                       (compilation-windows-restrict-file-acl pathname)
                       (write-sequence octets stream)
                       (finish-output stream))
                  (close stream))
                (return pathname)
          :finally (error "Cannot create a private compilation script"))))

#+os-windows
(defun compilation-windows-adopt-process (session)
  "Assign the just-launched Bash to the session's Job and arm control.
On failure the gated Bash is terminated directly: it has not run any
part of the command yet, so killing that single process is complete
cleanup (and its gate `read' fails closed when stdin is reaped anyway)."
  (let* ((pid (compilation-session-pid session))
         (handle (and (integerp pid)
                      (plusp pid)
                      (%compilation-win32-open-process
                       +compilation-win32-process-adopt-access+ 0 pid))))
    (when (or (null handle) (zerop handle))
      (error "Cannot open the compilation Bash process"))
    (unwind-protect
         (if (zerop (%compilation-win32-assign-process-to-job-object
                     (compilation-session-job session) handle))
             (progn
               (ignore-errors
                 (%compilation-win32-terminate-process
                  handle +compilation-win32-kill-exit-code+))
               (error "Cannot assign the compilation Bash to its Job"))
             (compilation-arm-control session))
      (ignore-errors (%compilation-win32-close-handle handle)))))

#+os-windows
(defun compilation-launch-process-windows (session)
  "Launch Bash inside a kill-on-close Job Object and gate its script.
Mirrors the POSIX launch contract: on return the session is armed and
the command is running; on error every OS resource is reclaimed."
  (let ((bash (or (compilation-bash-program)
                  (editor-error
                   "Compilation requires Git for Windows or MSYS2 Bash; none was found")))
        (job (%compilation-win32-create-job-object 0 0)))
    (when (zerop job)
      (editor-error "Cannot create a compilation Job Object"))
    (setf (compilation-session-job session) job)
    (handler-case
        (progn
          (unless (compilation-windows-set-job-limit-flags
                   job +compilation-win32-job-limit-kill-on-job-close+)
            (error "Cannot configure the compilation Job Object"))
          (setf (compilation-session-script-pathname session)
                (compilation-windows-create-script
                 (compilation-session-command session)))
          (let ((process
                  (uiop:launch-program
                   (list (namestring bash) "--noprofile" "--norc"
                         (uiop:native-namestring
                          (compilation-session-script-pathname session)))
                   :directory (compilation-session-directory session)
                   ;; The captured project environment reaches Bash as its
                   ;; ordinary environment block; only the script path is
                   ;; ever visible in process arguments.
                   :environment (compilation-session-environment session)
                   :input :stream
                   :output :stream
                   :error-output :output
                   :element-type '(unsigned-byte 8))))
            (setf (compilation-session-process session) process
                  (compilation-session-pid session)
                  (uiop:process-info-pid process))
            (compilation-windows-adopt-process session)
            ;; Bash's first script line blocks reading this gate, so no
            ;; part of the command could run before the Job assignment.
            (compilation-write-guardian-line session "START")
            process))
      (error (condition)
        (if (compilation-control-armed-p session)
            (compilation-force-stop session)
            (bt2:with-lock-held ((compilation-session-control-lock session))
              (ignore-errors
                (%compilation-win32-terminate-job-object
                 job +compilation-win32-kill-exit-code+))))
        (compilation-reap-process session)
        (error condition)))))

#+os-windows
(defun compilation-reader-worker-windows (session)
  "Drain Bash's merged output until its process exits, then reap and report.
Unlike the POSIX reader there is no control protocol: process liveness is
authoritative, and pipe EOF is deliberately ignored because descendants
inherit the output handle."
  (let ((process (compilation-session-process session))
        (octet-count 0)
        (utf8-tail (make-array 0 :element-type '(unsigned-byte 8)))
        (overflow-p nil)
        (reader-error nil)
        (force-kill-sent-p nil))
    (handler-case
        (let ((stream (uiop:process-info-output process))
              (chunk (make-array 8192 :element-type '(unsigned-byte 8))))
          (loop
            (when (and (not force-kill-sent-p)
                       (compilation-session-interrupted-p session)
                       (compilation-interrupt-deadline-reached-p session))
              (compilation-force-stop session)
              (setf force-kill-sent-p t))
            (multiple-value-bind (length output-eof-p)
                (compilation-read-live-octets stream chunk)
              (declare (ignore output-eof-p))
              (let* ((remaining (- *compilation-output-limit* octet-count))
                     (accepted (max 0 (min remaining length))))
                (when (plusp accepted)
                  (incf octet-count accepted)
                  (multiple-value-bind (text tail)
                      (compilation-decode-utf8-prefix
                       utf8-tail chunk accepted)
                    (setf utf8-tail tail)
                    (when (plusp (length text))
                      (compilation-queue-event
                       (lambda ()
                         (compilation-deliver-chunk session text))))))
                (when (< accepted length)
                  (setf overflow-p t)
                  (compilation-force-stop session)
                  (setf force-kill-sent-p t)
                  (return))
                (when (and (not (uiop:process-alive-p process))
                           (compilation-output-burst-drained-p length chunk))
                  (when (plusp (length utf8-tail))
                    (error
                     "Compilation output ended within a UTF-8 character"))
                  (return))
                (when (zerop length)
                  (sleep 0.01))))))
      (error (condition)
        (unless (member (compilation-session-state session)
                        '(:replaced :buffer-killed :reload :editor-exit))
          (setf reader-error (princ-to-string condition))
          ;; Nobody drains the pipe once decoding fails; stop the Job
          ;; before waiting so a verbose tree cannot block on a full
          ;; stdout buffer.
          (compilation-force-stop session))))
    (unless (or overflow-p reader-error)
      (compilation-windows-release-job session))
    (let ((exit-code (compilation-reap-process session)))
      (setf (compilation-session-interrupt-deadline session) nil)
      (compilation-queue-event
       (lambda ()
         (compilation-deliver-exit
          session exit-code reader-error overflow-p))))))

(defun compilation-exit-message (session exit-code reader-error overflow-p)
  (cond
    (overflow-p
     (format nil
             "Compilation stopped: output exceeded ~d bytes"
             (compilation-session-output-limit session)))
    ((compilation-session-interrupted-p session)
     "Compilation cancelled")
    (reader-error
     (format nil "Compilation reader failed: ~a" reader-error))
    ((and (integerp exit-code) (zerop exit-code))
     "Compilation finished")
    (t
     (format nil "Compilation exited abnormally with code ~a" exit-code))))

(defun compilation-deliver-exit (session exit-code reader-error overflow-p)
  ;; Lifecycle state remains authoritative even when the view has been killed.
  (compilation-disarm-control session)
  (setf (compilation-session-process session) nil
        (compilation-session-pid session) nil
        (compilation-session-reader-thread session) nil
        (compilation-session-state session)
        (if (and (eql exit-code 0) (not reader-error) (not overflow-p)
                 (not (compilation-session-interrupted-p session)))
            :finished
            (if (compilation-session-interrupted-p session) :interrupted :failed)))
  (when (compilation-session-owns-buffer-p session)
    (compilation-finish-pending-line session)
    (let ((status (compilation-exit-message session exit-code reader-error overflow-p)))
      (compilation-append-plain session (format nil "~%~a at ~a~%" status (compilation-time-string)))
      (message "~a" status))))

#+linux
(defun compilation-schedule-output-locked (session)
  ;; One queued editor event per session, bounded by the total output budget.
  (unless (compilation-session-output-event-p session)
    (setf (compilation-session-output-event-p session) t)
    (send-event (lambda () (compilation-flush-managed-output session)))))

#+linux
(defun compilation-flush-managed-output (session)
  (multiple-value-bind (chunks result)
      (bt2:with-lock-held ((compilation-session-control-lock session))
        (let* ((ordered (nreverse (compilation-session-pending-output session)))
               ;; Give other clients and commands a turn during a large burst.
               (batch (loop repeat 16 while ordered collect (pop ordered))))
          (setf (compilation-session-pending-output session) (nreverse ordered)
                (compilation-session-output-event-p session) nil)
          (when (compilation-session-pending-output session)
            (compilation-schedule-output-locked session))
          (values batch (unless (compilation-session-pending-output session)
                          (compilation-session-terminal-result session)))))
    (dolist (chunk chunks) (compilation-deliver-chunk session chunk))
    (when (and result (not (compilation-session-terminal-delivered-p session)))
      (setf (compilation-session-terminal-delivered-p session) t)
      (let ((state (gethash "state" result)))
        (when (and (equal state "cancelled")
                   (not (compilation-session-output-overflow-p session))
                   (not (compilation-session-output-error session)))
          (setf (compilation-session-interrupted-p session) t))
        (compilation-deliver-exit
         session (gethash "exit-code" result)
         (or (compilation-session-output-error session)
             (unless (member state '("exited" "cancelled") :test #'equal)
               (format nil "~a: ~a" state (gethash "reason" result))))
         (compilation-session-output-overflow-p session))))))

#+linux
(defun compilation-launch-managed-job (session)
  (let* ((manager (ensure-toolkit-job-manager))
         (bash (or (compilation-bash-program) (editor-error "Bash is unavailable")))
         (tails (make-hash-table :test #'eq))
         (limit (compilation-session-output-limit session))
         (job
           (lem-toolkit/jobs:start-job
            (list (namestring bash) "--noprofile" "--norc" "-c"
                  "IFS= read -r -d '' lem_compilation_script; exec </dev/null 2>&1; eval \"$lem_compilation_script\"")
            :manager manager :owner "human/compilation"
            :directory (uiop:native-namestring (compilation-session-directory session))
            :environment (compilation-session-environment session)
            ;; The shell command and environment use private pipes, never argv
            ;; or the durable journal. Deliberate shell output is still recorded.
            :input (concatenate 'string (compilation-session-command session) (string #\Null))
            :timeout 86400 :output-limit (min limit (* 1024 1024))
            :on-output
            (lambda (job channel octets)
              (handler-case
                  (let* ((remaining (- limit (compilation-session-output-octets session)))
                         (accepted (max 0 (min remaining (length octets)))))
                    (incf (compilation-session-output-octets session) accepted)
                    (when (plusp accepted)
                      (multiple-value-bind (text tail)
                          (compilation-decode-utf8-prefix
                           (or (gethash channel tails)
                               (make-array 0 :element-type '(unsigned-byte 8)))
                           octets accepted)
                        (setf (gethash channel tails) tail)
                        (when (plusp (length text))
                          (bt2:with-lock-held ((compilation-session-control-lock session))
                            (push text (compilation-session-pending-output session))
                            (compilation-schedule-output-locked session)))))
                    (when (< accepted (length octets))
                      (setf (compilation-session-output-overflow-p session) t)
                      (lem-toolkit/jobs:cancel-job job)))
                (error (condition)
                  (setf (compilation-session-output-error session) (princ-to-string condition))
                  (error condition)))))))
    (setf (compilation-session-managed-job session) job
          (compilation-session-state session) :running)
    ;; This waiter is an adapter worker, never the editor or output consumer.
    (setf (compilation-session-reader-thread session)
          (bt2:make-thread
           (lambda ()
             (let ((result (lem-toolkit/jobs:wait-job job)))
               (unless (or (compilation-session-output-error session)
                           (compilation-session-output-overflow-p session))
                 (when (loop for tail being the hash-values of tails
                             thereis (plusp (length tail)))
                   (setf (compilation-session-output-error session)
                         "Compilation output ended within a UTF-8 character")))
               (bt2:with-lock-held ((compilation-session-control-lock session))
                 (setf (compilation-session-terminal-result session) result)
                 (compilation-schedule-output-locked session))))
           :name "lem-yath/compilation-result"))
    job))

(defun compilation-render-header (session)
  (let ((buffer (compilation-session-buffer session)))
    (with-buffer-read-only buffer nil
      (erase-buffer buffer)
      (insert-string
       (buffer-start-point buffer)
       (format nil
               "-*- mode: compilation; default-directory: ~s -*-~%Compilation started at ~a~%~a~%~%"
               (uiop:native-namestring
                (compilation-session-directory session))
               (compilation-time-string)
               (compilation-session-command session)))
      (buffer-end (buffer-point buffer)))
    (buffer-unmark buffer)
    (setf (compilation-session-next-output-line session)
          (line-number-at-point (buffer-end-point buffer)))))

(defun compilation-start-session
    (origin-buffer origin-window command directory environment)
  (when *compilation-session*
    (compilation-detach-session *compilation-session* :replaced))
  (let* ((buffer (make-buffer *compilation-buffer-name*
                              :enable-undo-p nil))
         (session
           (make-compilation-session
            :buffer buffer
            :origin-buffer origin-buffer
            :origin-window origin-window
            :command command
            :directory directory
            :environment environment)))
    (buffer-disable-undo buffer)
    (setf (buffer-directory buffer) directory
          (buffer-value buffer 'lem-yath-direnv-process-buffer) t)
    (change-buffer-mode buffer 'lem-yath-compilation-mode)
    (setf (buffer-value buffer :lem-yath-compilation-session) session)
    (compilation-render-header session)
    (handler-case
        (progn
          #+linux (compilation-launch-managed-job session)
          #+os-windows
          (progn
            (compilation-launch-process-windows session)
            (setf (compilation-session-reader-thread session)
                  (bt2:make-thread
                   (lambda () (compilation-reader-worker-windows session))
                   :name "lem-yath/compilation-reader")
                  (compilation-session-state session) :running))
          (setf *compilation-session* session
                *lem-yath-next-error-source* :compilation)
          (let ((window (pop-to-buffer buffer)))
            (setf (current-window) window)
            ;; Emacs's default `compilation-scroll-output' is NIL: new output
            ;; does not drag point away from the beginning of the log.
            (buffer-start (current-point)))
          (message "Compilation started")
          session)
      (error (condition)
        (compilation-detach-session session :failed-to-start)
        (editor-error "Cannot start compilation: ~a" condition)))))

(defun compilation-confirm-running-replacement ()
  (or (not (compilation-process-alive-p *compilation-session*))
      (prompt-for-y-or-n-p
       "A compilation process is running; kill it")))

(define-command lem-yath-compile () ()
  "Prompt for and run a shell compilation in the current buffer directory."
  (compilation-ensure-supported)
  (let* ((origin-buffer (current-buffer))
         (origin-window (current-window))
         (directory (compilation-directory-for-buffer origin-buffer))
         (environment (lint-capture-environment))
         (command
           (prompt-for-string
            (format nil "Compile [~a]: "
                    (uiop:native-namestring directory))
            :initial-value (compilation-command-for-buffer origin-buffer)
            :history-symbol 'lem-yath-compile)))
    (when (zerop (length
                  (string-trim '(#\Space #\Tab #\Newline #\Return)
                               command)))
      (editor-error "Compilation command is empty"))
    (setf (compilation-command-for-buffer origin-buffer) command)
    (when (and (compilation-confirm-running-replacement)
               (compilation-save-before-start origin-buffer origin-window))
      (compilation-start-session origin-buffer origin-window command
                                 directory environment))))

(define-command lem-yath-recompile () ()
  "Rerun the last compilation with its exact command, directory, and environment."
  (compilation-ensure-supported)
  (let ((session (or (and (eq (buffer-major-mode (current-buffer))
                              'lem-yath-compilation-mode)
                          (buffer-value (current-buffer)
                                        :lem-yath-compilation-session))
                     *compilation-session*)))
    (unless session
      (editor-error "There is no previous compilation"))
    (let ((origin-buffer (compilation-session-origin-buffer session))
          (origin-window (compilation-session-origin-window session)))
      (unless (compilation-live-buffer-p origin-buffer)
        (editor-error "The compilation's originating buffer was killed"))
      (when (and (compilation-confirm-running-replacement)
                 (compilation-save-before-start origin-buffer origin-window))
        (compilation-start-session
         origin-buffer origin-window
         (compilation-session-command session)
         (compilation-session-directory session)
         (copy-list (compilation-session-environment session)))))))

(define-command lem-yath-interrupt-compilation () ()
  "Cancel the current compilation job and its process group immediately."
  (let ((session (or (buffer-value (current-buffer)
                                   :lem-yath-compilation-session)
                     *compilation-session*)))
    (unless (compilation-process-alive-p session)
      (editor-error "No compilation is running"))
    (unless (compilation-request-interrupt session)
      (editor-error "Compilation process group is no longer available"))
    (message "Compilation cancellation requested")))

;;; Navigation --------------------------------------------------------------

(defun compilation-session-for-navigation ()
  (let ((local (buffer-value (current-buffer)
                             :lem-yath-compilation-session)))
    (or local *compilation-session*)))

(defun compilation-diagnostic-index-at-point (session)
  (or (text-property-at
       (current-point) :lem-yath-compilation-diagnostic-index)
      (let ((diagnostic
              (gethash (line-number-at-point (current-point))
                       (compilation-session-diagnostics-by-line session))))
        (and diagnostic
             (position diagnostic
                       (compilation-session-diagnostics session)
                       :test #'eq)))))

(defun compilation-target-window (session source-buffer preserve-window)
  (let ((window (compilation-session-origin-window session)))
    (cond
      ((and window
            (not (deleted-window-p window))
            (not (eq window preserve-window)))
       window)
      (preserve-window
       ;; `go' promises to leave the compilation log selected.  If its saved
       ;; origin window was deleted, display the source in a new (or already
       ;; existing) window instead of replacing the sole log window.
       (with-current-window preserve-window
         (pop-to-buffer source-buffer :split-action :sensibly)))
      (t
       (current-window)))))

(defun compilation-visit-diagnostic
    (session diagnostic index &optional preserve-window)
  (let ((pathname (compilation-diagnostic-pathname diagnostic)))
    (unless (probe-file pathname)
      (editor-error "Compilation source no longer exists: ~a"
                    (uiop:native-namestring pathname)))
    (let ((buffer (find-file-buffer pathname))
          (window nil))
      (setf window
            (compilation-target-window session buffer preserve-window))
      (with-current-window window
        (lem/language-mode::push-location-stack (current-point))
        (lem-vi-mode/jumplist:with-jumplist
          (switch-to-buffer buffer)
          (move-to-line (current-point)
                        (compilation-diagnostic-line diagnostic))
          (line-start (current-point))
          (move-to-column
           (current-point)
           (max 0 (1- (compilation-diagnostic-column diagnostic)))))
        (window-recenter window))
      (setf (current-window) window
            (compilation-session-current-diagnostic-index session) index)
      (message "~a" (compilation-diagnostic-message diagnostic))
      diagnostic)))

(defun compilation-relative-diagnostic-index (session direction)
  (let* ((diagnostics (compilation-session-diagnostics session))
         (count (length diagnostics))
         (current (compilation-session-current-diagnostic-index session)))
    (when (zerop count)
      (editor-error "The compilation has no source diagnostics"))
    (let ((index (if current
                     (+ current direction)
                     (if (plusp direction) 0 (1- count)))))
      (unless (<= 0 index (1- count))
        (editor-error (if (plusp direction)
                          "Past last compilation error"
                          "Moved before first compilation error")))
      index)))

(defun compilation-select-diagnostic (direction)
  "Move within the compilation log without selecting a source window."
  (let ((session (compilation-session-for-navigation)))
    (unless (and session
                 (compilation-session-owns-buffer-p session)
                 (eq (current-buffer) (compilation-session-buffer session)))
      (editor-error "Not in a compilation buffer"))
    (let* ((diagnostics (compilation-session-diagnostics session))
           (point-index (compilation-diagnostic-index-at-point session))
           (line (line-number-at-point (current-point)))
           (index
             (cond
               (point-index (+ point-index direction))
               ((plusp direction)
                (position-if
                 (lambda (diagnostic)
                   (> (compilation-diagnostic-output-line diagnostic) line))
                 diagnostics))
               (t
                (position-if
                 (lambda (diagnostic)
                   (< (compilation-diagnostic-output-line diagnostic) line))
                 diagnostics :from-end t)))))
      (unless (and index (<= 0 index (1- (length diagnostics))))
        (editor-error (if (plusp direction)
                          "Past last compilation error"
                          "Moved before first compilation error")))
      (let ((diagnostic (aref diagnostics index)))
        (move-to-line (current-point)
                      (compilation-diagnostic-output-line diagnostic))
        (line-start (current-point))
        (setf (compilation-session-current-diagnostic-index session) index)
        (message "~a" (compilation-diagnostic-message diagnostic))
        diagnostic))))

(defun compilation-select-different-file (direction)
  "Move to the next diagnostic belonging to a different source file."
  (let ((session (compilation-session-for-navigation)))
    (unless (and session
                 (compilation-session-owns-buffer-p session)
                 (eq (current-buffer) (compilation-session-buffer session)))
      (editor-error "Not in a compilation buffer"))
    (let* ((diagnostics (compilation-session-diagnostics session))
           (count (length diagnostics))
           (point-index (compilation-diagnostic-index-at-point session))
           (line (line-number-at-point (current-point)))
           (current-path
             (and point-index
                  (compilation-diagnostic-pathname
                   (aref diagnostics point-index))))
           (index
             (if point-index
                 (if (plusp direction)
                     (loop :for candidate :from (1+ point-index) :below count
                           :unless (equal current-path
                                          (compilation-diagnostic-pathname
                                           (aref diagnostics candidate)))
                             :return candidate)
                     (loop :for candidate :downfrom (1- point-index) :to 0
                           :unless (equal current-path
                                          (compilation-diagnostic-pathname
                                           (aref diagnostics candidate)))
                             :return candidate))
                 (if (plusp direction)
                     (position-if
                      (lambda (diagnostic)
                        (> (compilation-diagnostic-output-line diagnostic) line))
                      diagnostics)
                     (position-if
                      (lambda (diagnostic)
                        (< (compilation-diagnostic-output-line diagnostic) line))
                      diagnostics :from-end t)))))
      (unless (and index (< index count))
        (editor-error (if (plusp direction)
                          "There is no later file in this compilation"
                          "There is no earlier file in this compilation")))
      (let ((diagnostic (aref diagnostics index)))
        (move-to-line (current-point)
                      (compilation-diagnostic-output-line diagnostic))
        (line-start (current-point))
        (setf (compilation-session-current-diagnostic-index session) index
              *lem-yath-next-error-source* :compilation)
        (message "~a" (compilation-diagnostic-message diagnostic))
        diagnostic))))

(defun compilation-visit-relative-diagnostic (direction)
  (let ((session (compilation-session-for-navigation)))
    (unless (and session (compilation-session-owns-buffer-p session))
      (editor-error "There is no compilation result buffer"))
    (let ((index (compilation-relative-diagnostic-index session direction)))
      (compilation-visit-diagnostic
       session
       (aref (compilation-session-diagnostics session) index)
       index))))

(define-command lem-yath-compilation-next-error () ()
  "Move to the next parsed diagnostic within the compilation log."
  (compilation-select-diagnostic 1)
  (setf *lem-yath-next-error-source* :compilation))

(define-command lem-yath-compilation-previous-error () ()
  "Move to the previous parsed diagnostic within the compilation log."
  (compilation-select-diagnostic -1)
  (setf *lem-yath-next-error-source* :compilation))

(define-command lem-yath-compilation-next-file () ()
  "Move forward to a diagnostic belonging to a different source file."
  (compilation-select-different-file 1))

(define-command lem-yath-compilation-previous-file () ()
  "Move backward to a diagnostic belonging to a different source file."
  (compilation-select-different-file -1))

(define-command lem-yath-compilation-display-error () ()
  "Display the current error's source without leaving the compilation log."
  (let* ((session (compilation-session-for-navigation))
         (index (and session
                     (compilation-diagnostic-index-at-point session))))
    (unless index
      (editor-error "There is no source location on this line"))
    (let ((compilation-window (current-window)))
      (compilation-visit-diagnostic
       session (aref (compilation-session-diagnostics session) index) index
       compilation-window)
      (unless (deleted-window-p compilation-window)
        (setf (current-window) compilation-window))
      (setf *lem-yath-next-error-source* :compilation))))

(define-command lem-yath-compilation-visit-error () ()
  "Visit the source location represented by the current compilation line."
  (let* ((session (compilation-session-for-navigation))
         (index (and session
                     (compilation-diagnostic-index-at-point session))))
    (unless index
      (editor-error "There is no source location on this line"))
    (compilation-visit-diagnostic
     session (aref (compilation-session-diagnostics session) index) index)
    (setf *lem-yath-next-error-source* :compilation)))

(define-command lem-yath-next-error () ()
  "Visit the next result from the active compilation or diagnostic source."
  (if (and (eq *lem-yath-next-error-source* :compilation)
           *compilation-session*
           (compilation-session-owns-buffer-p *compilation-session*))
      (compilation-visit-relative-diagnostic 1)
      (lem-yath-next-diagnostic)))

(define-command lem-yath-previous-error () ()
  "Visit the previous result from the active compilation or diagnostic source."
  (if (and (eq *lem-yath-next-error-source* :compilation)
           *compilation-session*
           (compilation-session-owns-buffer-p *compilation-session*))
      (compilation-visit-relative-diagnostic -1)
      (lem-yath-previous-diagnostic)))

;;; Hooks and bindings ------------------------------------------------------

(defun compilation-kill-buffer-hook (buffer)
  (let ((session (buffer-value buffer :lem-yath-compilation-session)))
    (when session
      (compilation-detach-session session :buffer-killed))))

(defun compilation-exit-editor-hook ()
  (when *compilation-session*
    (compilation-detach-session *compilation-session* :editor-exit)))

(defun compilation-cleanup-for-reload ()
  (when *compilation-session*
    (compilation-detach-session *compilation-session* :reload))
  (clrhash *compilation-attribute-cache*))

(define-key *lem-yath-compilation-mode-keymap* "Return"
  'lem-yath-compilation-visit-error)
(define-key *lem-yath-compilation-mode-keymap* "g j"
  'lem-yath-compilation-next-error)
(define-key *lem-yath-compilation-mode-keymap* "g k"
  'lem-yath-compilation-previous-error)
(define-key *lem-yath-compilation-mode-keymap* "C-j"
  'lem-yath-compilation-next-error)
(define-key *lem-yath-compilation-mode-keymap* "C-k"
  'lem-yath-compilation-previous-error)
(define-key *lem-yath-compilation-mode-keymap* "Tab"
  'lem-yath-compilation-next-error)
(define-key *lem-yath-compilation-mode-keymap* "S-Tab"
  'lem-yath-compilation-previous-error)
(define-key *lem-yath-compilation-mode-keymap* "g o"
  'lem-yath-compilation-display-error)
(define-key *lem-yath-compilation-mode-keymap* "M-Return"
  'lem-yath-compilation-display-error)
(define-key *lem-yath-compilation-mode-keymap* "S-Return"
  'lem-yath-compilation-display-error)
(define-key *lem-yath-compilation-mode-keymap* "[ ["
  'lem-yath-compilation-previous-file)
(define-key *lem-yath-compilation-mode-keymap* "] ]"
  'lem-yath-compilation-next-file)
(define-key *lem-yath-compilation-mode-keymap* "g r" 'lem-yath-recompile)
(define-key *lem-yath-compilation-mode-keymap* "C-c C-k"
  'lem-yath-interrupt-compilation)
(define-key *lem-yath-compilation-mode-keymap* "q" 'quit-active-window)
(define-key *lem-yath-compilation-mode-keymap* "Z Z" 'quit-active-window)
(define-key *lem-yath-compilation-mode-keymap* "Z Q"
  'lem-vi-mode/commands:vi-quit)

(remove-hook (variable-value 'kill-buffer-hook :global t)
             'compilation-kill-buffer-hook)
(add-hook (variable-value 'kill-buffer-hook :global t)
          'compilation-kill-buffer-hook)
(remove-hook *exit-editor-hook* 'compilation-exit-editor-hook)
(add-hook *exit-editor-hook* 'compilation-exit-editor-hook)
