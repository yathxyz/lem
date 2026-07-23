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
(defparameter *compilation-environment-limit* (* 16 1024 1024)
  "Maximum captured environment bytes sent to the private guardian.")
(defparameter *compilation-environment-entry-limit* 65536
  "Maximum captured environment entries sent to the private guardian.")
(defparameter *compilation-command-limit* (* 1024 1024)
  "Maximum UTF-8 command bytes sent to the private guardian.")
(defparameter *compilation-environment-magic*
  (make-array 8
              :element-type '(unsigned-byte 8)
              :initial-contents '(76 69 77 69 78 86 49 0)))

(defun compilation-find-runtime-program (name)
  "Resolve NAME from the wrapper's immutable runtime path when available."
  (or (loop :for directory
              :in (uiop:split-string
                   (or (uiop:getenv "LEM_YATH_RUNTIME_PATH") "")
                   :separator ":")
            :for candidate :=
              (and (plusp (length directory))
                   (merge-pathnames
                    name (uiop:ensure-directory-pathname directory)))
            :when (and candidate
                       (ignore-errors (probe-file candidate))
                       (not (uiop:directory-pathname-p candidate)))
              :return candidate)
      (executable-find name)))

(defun compilation-find-pinned-runtime-program (variable name)
  "Resolve a wrapper-pinned absolute program, falling back to runtime NAME."
  (let* ((value (uiop:getenv variable))
         (candidate
           (and value
                (plusp (length value))
                (ignore-errors (pathname value)))))
    (or (and candidate
             (uiop:absolute-pathname-p candidate)
             (ignore-errors (probe-file candidate))
             (not (uiop:directory-pathname-p candidate))
             candidate)
        (compilation-find-runtime-program name))))

;; Cache trusted executables before a selected project can change PATH.
(defvar *compilation-bash-program*
  (compilation-find-runtime-program "bash"))
(defvar *compilation-guardian-python-program*
  (compilation-find-pinned-runtime-program
   "LEM_YATH_GUARDIAN_PYTHON" "python3"))
(defvar *compilation-nproc-program*
  (compilation-find-runtime-program "nproc"))
(defvar *compilation-guardian-path*
  (or (ignore-errors
        (probe-file
         (asdf:system-relative-pathname
          :lem-yath "src/compilation-guardian.py")))
      (ignore-errors
        (probe-file
         (asdf:system-relative-pathname
          :lem-yath "compilation-guardian.py")))))

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
  (let ((process (and session (compilation-session-process session))))
    (and process
         (bt2:with-lock-held ((compilation-session-control-lock session))
           (compilation-session-control-armed-p session))
         (member (compilation-session-state session)
                 '(:starting :running :interrupting)))))

(defun compilation-number-of-processors ()
  "Return the affinity-aware processor count used by Emacs 31's default."
  (or (ignore-errors
        (let* ((program *compilation-nproc-program*)
               (output (and program
                            (uiop:run-program (list (namestring program))
                                              :output :string
                                              :error-output :string
                                              :environment
                                              '("LC_ALL=C" "PATH="))))
               (count (and output
                           (parse-integer output :junk-allowed t))))
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

(defun compilation-send-guardian-command (session command &key disarm)
  "Ask SESSION's live guardian to signal its anchored command group.

Lem stores no command-group ID and signals only through this private control
pipe.  A request therefore fails closed if the guardian has exited, while the
control lock serializes interrupt, release, and teardown requests."
  (when session
    (bt2:with-lock-held ((compilation-session-control-lock session))
      (let ((sent-p
              (and (compilation-session-control-armed-p session)
                   (ignore-errors
                     (compilation-write-guardian-line session command)
                     t))))
        (when (or disarm (not sent-p))
          (setf (compilation-session-control-armed-p session) nil))
        sent-p))))

(defun compilation-force-stop (session)
  ;; The live broker signals a separately anchored command group whose leader
  ;; remains unreaped.  Lem disarms the capability with the same lock hold.
  (compilation-send-guardian-command session "KILL" :disarm t))

(defun compilation-stop-process-group-as (session state)
  "Set terminal STATE, request group SIGKILL, and disarm atomically."
  (bt2:with-lock-held ((compilation-session-control-lock session))
    (setf (compilation-session-state session) state)
    (when (compilation-session-control-armed-p session)
      (ignore-errors
        (compilation-write-guardian-line session "KILL")))
    (setf (compilation-session-control-armed-p session) nil)))

(defun compilation-request-interrupt (session)
  "Atomically arm the grace deadline and ask the live broker for SIGINT."
  (bt2:with-lock-held ((compilation-session-control-lock session))
    (when (compilation-session-control-armed-p session)
      (setf (compilation-session-interrupted-p session) t
            (compilation-session-state session) :interrupting
            (compilation-session-interrupt-deadline session)
            (or (compilation-session-interrupt-deadline session)
                (+ (get-internal-real-time)
                   (round (* *compilation-force-kill-delay*
                             internal-time-units-per-second)))))
      (let ((sent-p
              (ignore-errors
                (compilation-write-guardian-line session "INT")
                t)))
        (unless sent-p
          (setf (compilation-session-control-armed-p session) nil))
        sent-p))))

(defun compilation-reap-process (session)
  "Wait for SESSION's guardian, close its streams, and clear OS handles."
  (let ((process (compilation-session-process session))
        (exit-code nil))
    (when process
      (setf exit-code (ignore-errors (uiop:wait-process process)))
      (ignore-errors (uiop:close-streams process)))
    (compilation-disarm-control session)
    (setf (compilation-session-process session) nil
          (compilation-session-pid session) nil)
    exit-code))

(defun compilation-detach-session (session state)
  (when session
    (let ((reader-thread (compilation-session-reader-thread session)))
      (compilation-stop-process-group-as session state)
      ;; Teardown is synchronous: the reader never waits for pipe EOF after
      ;; guardian exit, so joining also works when an out-of-group descendant
      ;; retains stdout.  This finishes old closures before reload/editor exit.
      (when reader-thread
        (bt2:join-thread reader-thread))
      (when (compilation-session-process session)
        (compilation-reap-process session))
      (setf (compilation-session-reader-thread session) nil
            (compilation-session-interrupt-deadline session) nil))
    (when (compilation-session-owns-buffer-p session)
      (setf (buffer-value (compilation-session-buffer session)
                          :lem-yath-compilation-session)
            nil))
    (when (eq *compilation-session* session)
      (setf *compilation-session* nil))
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

(defun compilation-write-uint32 (stream value)
  (let ((octets (make-array 4 :element-type '(unsigned-byte 8))))
    (dotimes (index 4)
      (setf (aref octets index)
            (ldb (byte 8 (* 8 (- 3 index))) value)))
    (write-sequence octets stream)))

(defun compilation-environment-entry-octets (entry)
  (unless (and (stringp entry)
               (let ((separator (position #\= entry)))
                 (and separator (plusp separator)))
               (not (find (code-char 0) entry)))
    (error "Compilation captured an invalid environment entry"))
  (babel:string-to-octets entry :encoding :utf-8 :errorp t))

(defun compilation-write-guardian-frame (session)
  "Send SESSION's environment and command without exposing either in argv."
  (let* ((environment (compilation-session-environment session))
         (entries
           (mapcar #'compilation-environment-entry-octets environment))
         (command
           (babel:string-to-octets
            (compilation-session-command session)
            :encoding :utf-8
            :errorp t))
         (environment-size (reduce #'+ entries :key #'length :initial-value 0))
         (stream
           (uiop:process-info-input
            (compilation-session-process session))))
    (when (> (length entries) *compilation-environment-entry-limit*)
      (error "Compilation environment has too many entries"))
    (when (> environment-size *compilation-environment-limit*)
      (error "Compilation environment exceeds ~d bytes"
             *compilation-environment-limit*))
    (when (> (length command) *compilation-command-limit*)
      (error "Compilation command exceeds ~d bytes"
             *compilation-command-limit*))
    (write-sequence *compilation-environment-magic* stream)
    (compilation-write-uint32 stream (length entries))
    (dolist (entry entries)
      (compilation-write-uint32 stream (length entry))
      (write-sequence entry stream))
    (compilation-write-uint32 stream (length command))
    (write-sequence command stream)
    (finish-output stream)))

(defun compilation-write-guardian-line (session line)
  (let ((stream (uiop:process-info-input
                 (compilation-session-process session))))
    (write-sequence (babel:string-to-octets
                     (format nil "~a~%" line)
                     :encoding :ascii)
                    stream)
    (finish-output stream)))

(defun compilation-read-guardian-line (stream)
  "Read one short trusted ASCII control line from the guardian."
  (let ((octets (make-array 16
                            :element-type '(unsigned-byte 8)
                            :adjustable t
                            :fill-pointer 0)))
    (loop
      :for octet := (read-byte stream nil :eof)
      :do
         (when (eq octet :eof)
           (error "Compilation guardian closed its control stream"))
         (when (= octet #x0a)
           (return (babel:octets-to-string octets :encoding :ascii)))
         (unless (<= octet #x7f)
           (error "Compilation guardian emitted non-ASCII control data"))
         (when (>= (length octets) 64)
           (error "Compilation guardian control line is too long"))
         (vector-push-extend octet octets))))

(defun compilation-parse-guardian-exit-line (line)
  (unless (uiop:string-prefix-p "EXIT " line)
    (error "Invalid compilation guardian control line: ~s" line))
  (let ((status (parse-integer line :start 5 :junk-allowed nil)))
    (unless (<= 0 status 255)
      (error "Invalid compilation child exit status: ~a" status))
    status))

(defun compilation-consume-guardian-control (tail buffer length)
  "Parse guardian control octets and return TAIL plus an optional exit code."
  (let ((text
          (with-output-to-string (stream)
            (write-string tail stream)
            (dotimes (index length)
              (let ((octet (aref buffer index)))
                (unless (<= octet #x7f)
                  (error "Compilation guardian emitted non-ASCII control data"))
                (write-char (code-char octet) stream))))))
    (when (> (length text) 64)
      (error "Compilation guardian control line is too long"))
    (let ((newline (position #\Newline text)))
      (if newline
          (let ((remainder (subseq text (1+ newline))))
            (when (or (plusp (length remainder))
                      (position #\Newline remainder))
              (error "Compilation guardian emitted extra control data"))
            (values ""
                    (compilation-parse-guardian-exit-line
                     (subseq text 0 newline))))
          (values text nil)))))

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

(defun compilation-release-guardian (session)
  "Disarm SESSION, then allow its live guardian to exit normally."
  (bt2:with-lock-held ((compilation-session-control-lock session))
    (when (and (compilation-session-control-armed-p session)
               (eq (compilation-session-state session) :running)
               (not (compilation-session-interrupted-p session)))
      ;; Once RELEASE is observable the guardian may exit and SBCL may reap it
      ;; asynchronously.  Drop the private control capability first.
      (setf (compilation-session-state session) :finalizing
            (compilation-session-control-armed-p session) nil)
      (compilation-write-guardian-line session "RELEASE")
      t)))

(defun compilation-reader-worker (session)
  (let ((process (compilation-session-process session))
        (octet-count 0)
        (utf8-tail (make-array 0 :element-type '(unsigned-byte 8)))
        (control-tail "")
        (command-exit-code nil)
        (overflow-p nil)
        (reader-error nil)
        (exit-code nil)
        (guardian-exited-p nil)
        (guardian-released-p nil)
        (force-kill-sent-p nil))
    (handler-case
        (let ((stream (uiop:process-info-output process))
              (control (uiop:process-info-error-output process)))
          (let ((chunk (make-array 8192
                                   :element-type '(unsigned-byte 8)))
                (control-chunk
                  (make-array 128 :element-type '(unsigned-byte 8))))
            (loop
              (when (and (not force-kill-sent-p)
                         (compilation-session-interrupted-p session)
                         (compilation-interrupt-deadline-reached-p session))
                (compilation-force-stop session)
                (setf force-kill-sent-p t))
              (multiple-value-bind (control-length control-eof-p)
                  (compilation-read-live-octets control control-chunk)
                (when (plusp control-length)
                  (multiple-value-bind (tail status)
                      (compilation-consume-guardian-control
                       control-tail control-chunk control-length)
                    (setf control-tail tail)
                    (when status
                      (when command-exit-code
                        (error "Compilation guardian repeated child status"))
                      (setf command-exit-code status
                            exit-code status))))
                (when (and (compilation-control-armed-p session)
                           (or control-eof-p
                               (not (uiop:process-alive-p process))))
                  ;; A trusted guardian normally cannot reach EOF while armed.
                  ;; LISTEN can report false at a silent EOF, so process
                  ;; liveness is the authoritative unexpected-death check.
                  (compilation-disarm-control session)
                  (error "Compilation guardian exited before release"))
              ;; Binary polling is required here.  READ-CHAR-NO-HANG can still
              ;; block on a partial UTF-8 code point while a descendant retains
              ;; the pipe.  Decode only complete, strictly valid prefixes.
                (multiple-value-bind (length output-eof-p)
                    (compilation-read-live-octets stream chunk)
                  (declare (ignore output-eof-p))
                  (let* ((remaining
                           (- *compilation-output-limit* octet-count))
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
                    (when (and command-exit-code
                               (not guardian-released-p)
                               (not (compilation-session-interrupted-p
                                     session))
                               (compilation-output-burst-drained-p
                                length chunk))
                      ;; EXIT is relayed only after the anchor has waited for
                      ;; Bash, so every foreground write precedes this poll.
                      ;; A zero-length underfull read is therefore drained;
                      ;; later descendant writes are outside normal completion.
                      (when (plusp (length utf8-tail))
                        ;; The command has already exited.  Disarm/release the
                        ;; guardian before reporting malformed terminal output;
                        ;; a descendant retaining stdout is not part of Lem's
                        ;; normal-completion cleanup contract.
                        (when (compilation-release-guardian session)
                          (setf guardian-released-p t)
                          (error
                           "Compilation output ended within a UTF-8 character")))
                      (unless (plusp (length utf8-tail))
                        (setf guardian-released-p
                              (not (null
                                    (compilation-release-guardian session))))))
                    ;; Query status only after the group was atomically
                    ;; disarmed by normal release or terminal SIGKILL.
                    (when (and (not guardian-exited-p)
                               (not (compilation-control-armed-p
                                     session))
                               (not (uiop:process-alive-p process)))
                      (setf guardian-exited-p t))
                    (when (and guardian-exited-p
                               (compilation-output-burst-drained-p
                                length chunk))
                      (when (and (not command-exit-code)
                                 (not force-kill-sent-p)
                                 (not (member
                                       (compilation-session-state session)
                                       '(:replaced :buffer-killed :reload
                                         :editor-exit))))
                        (error
                         "Compilation guardian exited without child status"))
                      (return))
                    (when (and (zerop length) (zerop control-length))
                      (sleep 0.01))))))))
      (error (condition)
        (unless (member (compilation-session-state session)
                        '(:replaced :buffer-killed :reload :editor-exit))
          (setf reader-error (princ-to-string condition))
          ;; Once decoding fails, nobody is draining the child's pipe.  Stop
          ;; the validated group before waiting so a verbose child cannot
          ;; block forever on a full stdout buffer.
          (compilation-force-stop session))))
    (let ((reaped-exit-code (compilation-reap-process session)))
      (unless (integerp exit-code)
        (setf exit-code reaped-exit-code))
      (when (and (integerp command-exit-code)
                 (integerp reaped-exit-code)
                 (not (compilation-session-interrupted-p session))
                 (/= command-exit-code reaped-exit-code))
        (setf reader-error
              (format nil
                      "Compilation guardian status ~d disagreed with child status ~d"
                      reaped-exit-code command-exit-code))))
    (setf (compilation-session-interrupt-deadline session) nil)
    (compilation-queue-event
     (lambda ()
       (compilation-deliver-exit
        session exit-code reader-error overflow-p)))))

(defun compilation-exit-message (session exit-code reader-error overflow-p)
  (cond
    (overflow-p
     (format nil
             "Compilation stopped: output exceeded ~d bytes"
             *compilation-output-limit*))
    ((compilation-session-interrupted-p session)
     "Compilation interrupted")
    (reader-error
     (format nil "Compilation reader failed: ~a" reader-error))
    ((and (integerp exit-code) (zerop exit-code))
     "Compilation finished")
    (t
     (format nil "Compilation exited abnormally with code ~a" exit-code))))

(defun compilation-deliver-exit
    (session exit-code reader-error overflow-p)
  (when (compilation-session-owns-buffer-p session)
    (compilation-finish-pending-line session)
    (let ((status (compilation-exit-message
                   session exit-code reader-error overflow-p)))
      (compilation-disarm-control session)
      (setf (compilation-session-process session) nil
            (compilation-session-pid session) nil
            (compilation-session-reader-thread session) nil
            (compilation-session-state session)
            (if (and (integerp exit-code)
                     (zerop exit-code)
                     (not reader-error)
                     (not overflow-p)
                     (not (compilation-session-interrupted-p session)))
                :finished
                (if (compilation-session-interrupted-p session)
                    :interrupted
                    :failed)))
      (compilation-append-plain
       session
       (format nil "~%~a at ~a~%" status (compilation-time-string)))
      (message "~a" status))))

(defun compilation-launch-process (session)
  (let ((bash (or *compilation-bash-program*
                  (editor-error "Pinned Bash is unavailable")))
        (python (or *compilation-guardian-python-program*
                    (editor-error "Pinned Python is unavailable")))
        (guardian (or *compilation-guardian-path*
                      (editor-error "Compilation guardian is unavailable"))))
    (let ((process
            (uiop:launch-program
             (list (namestring python)
                   (namestring guardian)
                   (namestring bash))
             :directory (compilation-session-directory session)
             ;; The guardian starts from a fixed environment; the captured
             ;; project environment and command arrive over private stdin and
             ;; never appear in the guardian's process arguments.
             :environment '("HOME=/" "LC_ALL=C" "PATH="
                            "PYTHONNOUSERSITE=1"
                            "PYTHONDONTWRITEBYTECODE=1")
             :input :stream
             :output :stream
             :error-output :stream
             :element-type '(unsigned-byte 8))))
      (setf (compilation-session-process session) process
            (compilation-session-pid session)
            (uiop:process-info-pid process))
      (handler-case
          (let ((control (uiop:process-info-error-output process)))
            ;; Before READY the guardian has no command child.  After READY it
            ;; blocks on Lem's private stdin and cannot exit on its own.
            (unless (string= "READY"
                             (compilation-read-guardian-line control))
              (error "Compilation guardian did not become ready"))
            (compilation-write-guardian-frame session)
            (unless (string= "ENV"
                             (compilation-read-guardian-line control))
              (error "Compilation guardian rejected its private frame"))
            (let* ((pid (compilation-session-pid session))
                   (guardian-pgid
                     (and (integerp pid)
                          (> pid 1)
                          (ignore-errors (sb-posix:getpgid pid)))))
              (unless (and (integerp guardian-pgid)
                           (= pid guardian-pgid))
                ;; No command was spawned, so closing the private control pipe
                ;; is sufficient to release the unarmed guardian.
                (error "Cannot isolate the compilation process group safely"))
              ;; The numeric guardian PGID is deliberately discarded.  Lem
              ;; retains the broker pipe plus its locked armed-state Boolean,
              ;; and never stores or signals the command group's numeric ID.
              (compilation-arm-control session))
            (compilation-write-guardian-line session "START")
            (unless (string= "STARTED"
                             (compilation-read-guardian-line control))
              (error "Compilation guardian did not start the command"))
            process)
        (error (condition)
          (if (compilation-control-armed-p session)
              (compilation-force-stop session)
              (ignore-errors
                (close (uiop:process-info-input process))))
          (compilation-reap-process session)
          (error condition))))))

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
          (compilation-launch-process session)
          (let ((reader-thread
                  (bt2:make-thread
                   (lambda () (compilation-reader-worker session))
                   :name "lem-yath/compilation-reader")))
            (setf (compilation-session-reader-thread session) reader-thread
                  (compilation-session-state session) :running
                  *compilation-session* session
                  *lem-yath-next-error-source* :compilation))
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
  "Interrupt the current compilation process group, then kill it if needed."
  (let ((session (or (buffer-value (current-buffer)
                                   :lem-yath-compilation-session)
                     *compilation-session*)))
    (unless (compilation-process-alive-p session)
      (editor-error "No compilation is running"))
    (unless (compilation-request-interrupt session)
      (editor-error "Compilation process group is no longer available"))
    (message "Compilation interrupt requested")))

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
