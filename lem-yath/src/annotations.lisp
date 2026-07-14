;;;; Marginalia-style display metadata for prompt completion.

(in-package :lem-yath)

(defparameter *completion-annotation-limit* 120)
(defparameter *completion-annotation-max-relative-age* (* 14 24 60 60))
(defparameter *completion-bookmark-context-byte-limit* (* 1024 1024))
(defparameter *completion-library-metadata-byte-limit* (* 64 1024))

(defun completion-annotation-one-line (text)
  "Return TEXT as one trimmed line without changing ordinary spacing."
  (when (stringp text)
    (string-trim
     '(#\Space)
     (map 'string
          (lambda (character)
            (if (or (< (char-code character) 32)
                    (= (char-code character) 127))
                #\Space
                character))
          text))))

(defun completion-first-documentation-line (text)
  (when (stringp text)
    (alexandria:when-let
        ((line
           (find-if
            (lambda (candidate)
              (plusp (length (string-trim '(#\Space #\Tab) candidate))))
            (ppcre:split "[\\r\\n]+" text))))
      (ppcre:regex-replace-all
       " +"
       (string-trim '(#\Space #\Tab) line)
       " "))))

(defun completion-path-display-string (string)
  "Escape control characters in STRING so it occupies one prompt row."
  (with-output-to-string (stream)
    (loop :for character :across string
          :for code := (char-code character)
          :do (case character
                (#\\ (write-string "\\\\" stream))
                (#\Newline (write-string "\\n" stream))
                (#\Return (write-string "\\r" stream))
                (#\Tab (write-string "\\t" stream))
                (otherwise
                 (if (or (< code 32) (= code 127))
                     (format stream "\\x~2,'0X;" code)
                     (write-char character stream)))))))

(defun completion-abbreviated-path (pathname)
  "Abbreviate a local PATHNAME below HOME without resolving symlinks."
  (let* ((name (uiop:native-namestring (pathname pathname)))
         (home
           (uiop:native-namestring
            (uiop:ensure-directory-pathname (user-homedir-pathname)))))
    (completion-path-display-string
     (if (alexandria:starts-with-subseq home name)
         (concatenate 'string "~/" (subseq name (length home)))
         name))))

(defun completion-bounded-annotation (text)
  "Bound one-line annotation TEXT to the terminal-safe display limit."
  (let ((text (completion-annotation-one-line text)))
    (cond
      ((or (null text) (zerop (length text))) "")
      ((<= (length text) *completion-annotation-limit*) text)
      (t
       (concatenate 'string
                    (subseq text 0 (1- *completion-annotation-limit*))
                    "…")))))

(defun completion-join-annotation-fields (&rest fields)
  (completion-bounded-annotation
   (format nil "~{~a~^  ~}"
           (remove-if (lambda (field)
                        (or (null field)
                            (and (stringp field)
                                 (zerop (length field)))))
                      fields))))

(defun completion-human-readable-size (size)
  "Format nonnegative SIZE like Emacs' file-size-human-readable."
  (unless (and (integerp size) (not (minusp size)))
    (return-from completion-human-readable-size ""))
  (if (< size 1024)
      (princ-to-string size)
      (loop :with value := (coerce size 'double-float)
            :for suffix :across "kMGTPEZY"
            :do (setf value (/ value 1024d0))
                (when (or (< value 1024d0) (char= suffix #\Y))
                  (return
                    (if (= value (round value))
                        (format nil "~d~c" (round value) suffix)
                        (format nil "~,1f~c" value suffix)))))))

(defun completion-set-detail (item detail)
  "Set display-only DETAIL on ITEM without changing candidate identity."
  (when (typep item 'lem/completion-mode:completion-item)
    (setf (lem/completion-mode:completion-item-detail item)
          (completion-bounded-annotation detail)))
  item)

(defun completion-annotate-leading-items (items function &optional (limit 100))
  "Apply FUNCTION to the leading LIMIT completion ITEMS in place."
  (loop :for item :in items
        :repeat limit
        :do (funcall function item))
  items)

(defun completion-make-prompt-item (label detail)
  "Create an annotated item which replaces the complete live prompt input."
  (with-point ((start (lem/prompt-window::current-prompt-start-point))
               (end (lem/prompt-window::current-prompt-start-point)))
    (lem/completion-mode:make-completion-item
     :label label
     :detail detail
     :start start
     :end (line-end end))))

(defun completion-annotated-prompt-choices
    (choices detail-function &optional (limit 100))
  "Turn leading label/value CHOICES into correctly ranged prompt items."
  (loop :for (label . value) :in choices
        :repeat limit
        :collect (completion-make-prompt-item
                  label (funcall detail-function value))))

;;; Commands -----------------------------------------------------------------

(defun completion-command-documentation (label)
  (handler-case
      (alexandria:when-let* ((command (find-command label))
                             (symbol
                               (lem/common/command:command-name command)))
        (completion-first-documentation-line
         (documentation symbol 'function)))
    (error () nil)))

(defun completion-command-leader-binding (label)
  "Return the first configured SPC binding for command LABEL, when available."
  (when (and (boundp '*evil-leader-bindings*)
             *evil-leader-bindings*)
    (handler-case
        (loop :for (keys command) :in *evil-leader-bindings*
              :when (string-equal label (string command))
                :return (format nil "SPC ~a" keys))
      (error () nil))))

(defun completion-annotate-command-item (item)
  (let* ((label (completion-label item))
         (binding (lem/completion-mode:completion-item-detail item))
         (leader-binding (completion-command-leader-binding label))
         (documentation (completion-command-documentation label)))
    (completion-set-detail
     item
     (completion-join-annotation-fields
      (cond
        (leader-binding (format nil "(~a)" leader-binding))
        ((and (stringp binding) (plusp (length binding)))
         (format nil "(~a)" binding)))
      documentation))))

;;; Buffers ------------------------------------------------------------------

(defun completion-buffer-status (buffer)
  (format nil "~c~c-"
          (cond
            ((buffer-read-only-p buffer) #\%)
            ((buffer-modified-p buffer) #\*)
            (t #\-))
          (cond
            ((buffer-modified-p buffer) #\*)
            ((buffer-read-only-p buffer) #\%)
            (t #\-))))

(defun completion-buffer-size (buffer)
  "Return BUFFER's size, caching the line walk until its content tick changes."
  (let* ((tick (buffer-modified-tick buffer))
         (cache (buffer-value buffer 'lem-yath-completion-size-cache)))
    (if (and (consp cache) (= tick (car cache)))
        (cdr cache)
        (let ((size (max 0 (1- (position-at-point
                                (buffer-end-point buffer))))))
          (setf (buffer-value buffer 'lem-yath-completion-size-cache)
                (cons tick size))
          size))))

(defun completion-buffer-detail (buffer &optional location)
  "Return Marginalia-style status, size, mode, and LOCATION for BUFFER."
  (handler-case
      (let* ((size (completion-buffer-size buffer))
             (mode (mode-name (buffer-major-mode buffer)))
             (location
               (or (and location (plusp (length location)) location)
                   (alexandria:when-let ((filename (buffer-filename buffer)))
                     (enough-namestring filename (probe-file "./"))))))
        (completion-join-annotation-fields
         (completion-buffer-status buffer)
         (format nil "~7@a" (completion-human-readable-size size))
         (format nil "~20a" mode)
         location))
    (error () "")))

(defun completion-annotate-buffer-item (item)
  (alexandria:when-let ((buffer (get-buffer (completion-label item))))
    (completion-set-detail
     item
     (completion-buffer-detail
      buffer (lem/completion-mode:completion-item-detail item)))))

;;; Files --------------------------------------------------------------------

(defun completion-file-mode-character (mode)
  (case (logand mode #o170000)
    (#o040000 #\d)
    (#o120000 #\l)
    (#o140000 #\s)
    (#o010000 #\p)
    (#o020000 #\c)
    (#o060000 #\b)
    (otherwise #\-)))

(defun completion-file-permission-character
    (mode permission execute special lower upper)
  (cond
    ((logtest special mode)
     (if (logtest execute mode) lower upper))
    ((logtest permission mode) #\x)
    (t #\-)))

(defun completion-file-mode-string (mode)
  (coerce
   (list
    (completion-file-mode-character mode)
    (if (logtest #o400 mode) #\r #\-)
    (if (logtest #o200 mode) #\w #\-)
    (completion-file-permission-character
     mode #o100 #o100 #o4000 #\s #\S)
    (if (logtest #o040 mode) #\r #\-)
    (if (logtest #o020 mode) #\w #\-)
    (completion-file-permission-character
     mode #o010 #o010 #o2000 #\s #\S)
    (if (logtest #o004 mode) #\r #\-)
    (if (logtest #o002 mode) #\w #\-)
    (completion-file-permission-character
     mode #o001 #o001 #o1000 #\t #\T))
   'string))

(defun completion-posix-call (name &rest arguments)
  (alexandria:when-let ((symbol (find-symbol name "SB-POSIX")))
    (when (fboundp symbol)
      (apply (symbol-function symbol) arguments))))

(defun completion-file-owner (stat)
  (let ((uid (sb-posix:stat-uid stat))
        (gid (sb-posix:stat-gid stat)))
    (unless (and (= uid (sb-posix:getuid))
                 (= gid (sb-posix:getgid)))
      (let* ((passwd (ignore-errors (completion-posix-call "GETPWUID" uid)))
             (group (ignore-errors (completion-posix-call "GETGRGID" gid)))
             (user (or (and passwd
                            (ignore-errors
                              (completion-posix-call "PASSWD-NAME" passwd)))
                       uid))
             (group-name (or (and group
                                  (ignore-errors
                                    (completion-posix-call "GROUP-NAME" group)))
                             gid)))
        (format nil "~a:~a" user group-name)))))

(defun completion-relative-age (seconds)
  (let* ((remaining (max 0 (floor seconds)))
         (units '((86400 . "d") (3600 . "h") (60 . "m") (1 . "s")))
         (fields nil))
    (dolist (unit units)
      (destructuring-bind (width . suffix) unit
        (multiple-value-bind (value rest) (floor remaining width)
          (setf remaining rest)
          (when (and (plusp value) (< (length fields) 2))
            (push (format nil "~d~a" value suffix) fields)))))
    (format nil "~{~a~^ ~} ago" (or (nreverse fields) '("0s")))))

(defparameter *completion-month-names*
  #("Jan" "Feb" "Mar" "Apr" "May" "Jun"
    "Jul" "Aug" "Sep" "Oct" "Nov" "Dec"))

(defun completion-file-time (unix-time)
  (let* ((universal-time (+ unix-time 2208988800))
         (now (get-universal-time))
         (age (- now universal-time)))
    (if (< age *completion-annotation-max-relative-age*)
        (completion-relative-age age)
        (multiple-value-bind (second minute hour day month year)
            (decode-universal-time universal-time)
          (declare (ignore second))
          (if (> (nth-value 5 (decode-universal-time now)) year)
              (format nil "~4,'0d ~a ~2,'0d"
                      year
                      (aref *completion-month-names* (1- month))
                      day)
              (format nil "~a ~2,'0d ~2,'0d:~2,'0d"
                      (aref *completion-month-names* (1- month))
                      day hour minute))))))

(defun completion-file-detail (pathname)
  "Return local file modes, size, age, and conditional owner for PATHNAME."
  (handler-case
      (let* ((native (etypecase pathname
                       (string pathname)
                       (pathname (uiop:native-namestring pathname))))
             (stat (sb-posix:lstat native))
             (mode (sb-posix:stat-mode stat))
             (size (sb-posix:stat-size stat))
             (time (sb-posix:stat-mtime stat))
             (owner (completion-file-owner stat)))
        (completion-join-annotation-fields
         (completion-file-mode-string mode)
         (format nil "~7@a" (completion-human-readable-size size))
         (format nil "~12a" (completion-file-time time))
         owner))
    (error () "")))

(defun completion-file-candidate-path (input directory label)
  "Resolve an already-produced component LABEL without rescanning its directory."
  (let* ((expanded (expand-file-name input directory))
         (input-directory (directory-namestring expanded)))
    (concatenate 'string input-directory label)))

(defun completion-annotate-file-items (items input directory)
  (completion-annotate-leading-items
   items
   (lambda (item)
     (completion-set-detail
      item
      (completion-file-detail
       (completion-file-candidate-path
        input directory (completion-label item)))))))

;;; Lisp libraries ----------------------------------------------------------

(defun completion-quicklisp-local-project-directories ()
  (handler-case
      (let ((symbol
              (uiop:find-symbol*
               :*local-project-directories* :quicklisp)))
        (when (boundp symbol)
          (symbol-value symbol)))
    (error () nil)))

(defun completion-library-asd-files ()
  "Return bundled and Quicklisp-local Lem library definitions."
  (let* ((lem-root (asdf:system-source-directory :lem))
         ;; Marginalia's library category covers the whole load path, not only
         ;; optional contribs.  The Nix image keeps all bundled ASDs here.
         (bundled-files
           (directory (merge-pathnames "**/lem-*.asd" lem-root)))
         (local-files
           (loop :for root
                   :in (completion-quicklisp-local-project-directories)
                 :append
                 (directory (merge-pathnames "**/lem-*.asd" root)))))
    (append bundled-files
            (set-difference local-files bundled-files
                            :test #'equal :key #'pathname-name))))

(defun completion-library-choices ()
  (let ((seen (make-hash-table :test #'equal))
        (choices nil))
    (dolist (file (completion-library-asd-files) (nreverse choices))
      (let ((stem (pathname-name file)))
        (when (and (stringp stem)
                   (alexandria:starts-with-subseq "lem-" stem)
                   (> (length stem) 4))
          (let ((name (subseq stem 4)))
            (unless (gethash name seen)
              (setf (gethash name seen) t)
              (push (cons name file) choices))))))))

(defun completion-library-form-metadata (pathname)
  "Read literal ASDF description/version fields without evaluating PATHNAME."
  (handler-case
      (let ((size (sb-posix:stat-size
                   (sb-posix:stat (uiop:native-namestring pathname)))))
        (when (<= size *completion-library-metadata-byte-limit*)
          (with-open-file (stream pathname :direction :input)
            (let ((*read-eval* nil))
              (loop :repeat 64
                    :for form := (read stream nil nil)
                    :while form
                    :when (and (consp form)
                               (symbolp (first form))
                               (string-equal
                                "DEFSYSTEM" (symbol-name (first form))))
                      :return
                      (let* ((options (cddr form))
                             (description
                               (ignore-errors
                                 (getf options :description)))
                             (version
                               (ignore-errors (getf options :version))))
                        (values
                         (and (stringp description)
                              (completion-first-documentation-line
                               description))
                         (and (or (stringp version) (numberp version))
                              (princ-to-string version)))))))))
    (error () (values nil nil))))

(defun completion-library-source-directory (pathname)
  (let ((directory
          (uiop:ensure-directory-pathname
           (uiop:pathname-directory-pathname pathname))))
    (or
     (loop :for system :in '(:lem :lem-contrib)
           :for root := (ignore-errors
                          (asdf:system-source-directory system))
           :for relative := (and root
                                 (ignore-errors
                                   (enough-namestring directory root)))
           :when (and relative
                      (not (alexandria:starts-with-subseq "../" relative)))
             :return (completion-path-display-string relative))
     (completion-abbreviated-path directory))))

(defun completion-library-detail (pathname)
  (handler-case
      (multiple-value-bind (description version)
          (completion-library-form-metadata pathname)
        (let ((system-name (pathname-name pathname)))
          (completion-join-annotation-fields
           (when (member system-name (asdf:already-loaded-systems)
                         :test #'string-equal)
             "Loaded")
           version
           description
           (completion-library-source-directory pathname))))
    (error () "")))

(defun completion-prompt-for-library (prompt &key history-symbol)
  "Read a Lem library with loaded state, metadata, and source annotations."
  (let ((choices (completion-library-choices))
        (details (make-hash-table :test #'equal)))
    (prompt-for-string
     prompt
     :completion-function
     (lambda (input)
       (completion-annotated-prompt-choices
        (prescient-filter input choices
                          :key #'car :category :library)
        (lambda (pathname)
          (or (gethash pathname details)
              (setf (gethash pathname details)
                    (completion-library-detail pathname))))))
     :test-function
     (lambda (name)
       (not (null (assoc name choices :test #'string=))))
     :history-symbol history-symbol)))

(defun completion-register-selected-library (name)
  "Register NAME's exact accepted ASD when the dumped image omitted it."
  (let ((system-name (format nil "lem-~a" name)))
    (unless (asdf:find-system system-name nil)
      (alexandria:when-let
          ((pathname
            (cdr (assoc name (completion-library-choices)
                        :test #'string=))))
        (asdf:load-asd pathname)))))

(define-command (lem-yath-load-library (:name "load-library")) (name)
    ((completion-prompt-for-library
      "load library: " :history-symbol 'load-library))
  "Load a Lisp library selected from an annotated prompt."
  (completion-register-selected-library name)
  (load-library name))

;;; Themes ------------------------------------------------------------------

(defun completion-theme-detail (theme-name)
  (handler-case
      (let* ((theme (find-color-theme theme-name))
             (parent (and theme (lem-core::color-theme-parent theme)))
             (roles (and theme
                         (length (lem-core::color-theme-specs theme)))))
        (completion-join-annotation-fields
         (when (string= theme-name (or (current-theme) "")) "Active")
         (if parent (format nil "inherits ~a" parent) "direct")
         (and roles (format nil "~d roles" roles))))
    (error () "")))

(defun completion-prompt-for-theme ()
  "Read a color theme with active, inheritance, and role annotations."
  (let ((choices
          (mapcar (lambda (name)
                    (cons name name))
                  (lem-core::all-color-themes))))
    (prompt-for-string
     "Color theme: "
     :completion-function
     (lambda (input)
       (completion-annotated-prompt-choices
        (prescient-filter input choices :key #'car :category :theme)
        #'completion-theme-detail))
     :test-function #'find-color-theme
     :history-symbol 'mh-color-theme)))

(define-command (lem-yath-load-theme (:name "load-theme"))
    (name &optional (save-theme t))
    ((completion-prompt-for-theme))
  "Load a color theme selected from an annotated prompt."
  (load-theme name save-theme))

;;; Install prompt producer wrappers -----------------------------------------

(defvar *completion-unannotated-command-function* nil)
(defvar *completion-unannotated-buffer-function* nil)
(defvar *completion-unannotated-file-function* nil)

(defun completion-annotated-command-function (input &rest arguments)
  (completion-annotate-leading-items
   (apply *completion-unannotated-command-function* input arguments)
   #'completion-annotate-command-item))

(defun completion-annotated-buffer-function (input &rest arguments)
  (completion-annotate-leading-items
   (apply *completion-unannotated-buffer-function* input arguments)
   #'completion-annotate-buffer-item))

(defun completion-annotated-file-function (input directory &rest arguments)
  (completion-annotate-file-items
   (apply *completion-unannotated-file-function* input directory arguments)
   input directory))

(defun completion-install-prompt-producers ()
  "Install annotation wrappers while retaining the freshest base providers."
  (unless (eq *prompt-command-completion-function*
              'completion-annotated-command-function)
    (setf *completion-unannotated-command-function*
          *prompt-command-completion-function*))
  (unless (eq *prompt-buffer-completion-function*
              'completion-annotated-buffer-function)
    (setf *completion-unannotated-buffer-function*
          *prompt-buffer-completion-function*))
  (unless (eq *prompt-file-completion-function*
              'completion-annotated-file-function)
    (setf *completion-unannotated-file-function*
          *prompt-file-completion-function*))
  (setf *prompt-command-completion-function*
        'completion-annotated-command-function
        *prompt-buffer-completion-function*
        'completion-annotated-buffer-function
        *prompt-file-completion-function*
        'completion-annotated-file-function))

(completion-install-prompt-producers)

;;; Recent files -------------------------------------------------------------

(define-command lem-yath-find-recent-file () ()
  "Open a recently accessed file with file metadata in the prompt."
  (let* ((filenames (lem-core/commands/file:recent-files))
         (choices (mapcar (lambda (filename)
                            (cons (completion-path-display-string filename)
                                  filename))
                          filenames)))
    (unless choices
      (editor-error "No file history."))
    (let ((choice
            (prompt-for-string
             "File: "
             :completion-function
             (lambda (input)
               (completion-annotated-prompt-choices
                (prescient-filter input choices
                                  :key #'car
                                  :category :file)
                #'completion-file-detail))
             :test-function
             (lambda (name)
               (assoc name choices :test #'string=)))))
      (when choice
        (find-file (cdr (assoc choice choices :test #'string=)))))))

;;; Bookmarks ---------------------------------------------------------------

(defun completion-bookmark-open-buffer (filename)
  "Return an existing file buffer for FILENAME without opening one."
  (let ((target (ignore-errors (expand-file-name filename))))
    (and target
         (find-if
          (lambda (buffer)
            (let ((buffer-file (buffer-filename buffer)))
              (and buffer-file
                   (string= target
                            (ignore-errors
                              (expand-file-name buffer-file))))))
          (buffer-list)))))

(defun completion-bookmark-file-text (filename)
  "Read bounded bookmark text without visiting FILENAME or running hooks."
  (handler-case
      (alexandria:if-let
          ((buffer (completion-bookmark-open-buffer filename)))
        (when (<= (completion-buffer-size buffer)
                  *completion-bookmark-context-byte-limit*)
          (points-to-string (buffer-start-point buffer)
                            (buffer-end-point buffer)))
        (let* ((native (uiop:native-namestring (pathname filename)))
               (stat (sb-posix:stat native))
               (mode (sb-posix:stat-mode stat)))
          (when (and (= #o100000 (logand mode #o170000))
                     (<= (sb-posix:stat-size stat)
                         *completion-bookmark-context-byte-limit*))
            (uiop:read-file-string filename))))
    (error () nil)))

(defun completion-bookmark-position-context (text position)
  "Return line, column, and the containing line for one-based POSITION."
  (when (and (stringp text)
             (integerp position)
             (<= 1 position (1+ (length text))))
    (let* ((index (1- position))
           (previous-newline
             (position #\Newline text :end index :from-end t))
           (line-start (if previous-newline (1+ previous-newline) 0))
           (next-newline (position #\Newline text :start index))
           (line-end (or next-newline (length text)))
           (line (1+ (count #\Newline text :end index)))
           (column (- index line-start))
           (context
             (completion-annotation-one-line
              (subseq text line-start line-end))))
      (values line column context))))

(defun completion-bookmark-file-kind (filename)
  (handler-case
      (case (completion-file-mode-character
             (sb-posix:stat-mode
              (sb-posix:lstat
               (uiop:native-namestring (pathname filename)))))
        (#\d "directory")
        (#\l "link")
        (#\s "socket")
        (#\p "fifo")
        ((#\c #\b) "device")
        (otherwise "file"))
    (error () "missing")))

(defun completion-bookmark-detail (entry)
  "Return type, path, position, and bounded context for bookmark ENTRY."
  (handler-case
      (let* ((filename (lem-bookmark:bookmark-filename entry))
             (position (lem-bookmark:bookmark-position entry))
             (kind (completion-bookmark-file-kind filename))
             (path (completion-abbreviated-path filename))
             (text (and position
                        (string/= kind "directory")
                        (completion-bookmark-file-text filename))))
        (multiple-value-bind (line column context)
            (completion-bookmark-position-context text position)
          (completion-join-annotation-fields
           kind
           path
           (cond
             (line (format nil "L~d:C~d" line column))
             (position (format nil "@~d" position)))
           context)))
    (error () "")))

(defun completion-prompt-for-bookmark (prompt)
  "Read a bookmark with lazy, display-only Marginalia-style metadata."
  (let ((choices
          (loop :for entry :being :the :hash-value
                  :in lem-bookmark::*bookmark-table*
                :collect (cons (lem-bookmark:bookmark-name entry)
                               entry))))
    (prompt-for-string
     prompt
     :completion-function
     (lambda (input)
       (completion-annotated-prompt-choices
        (prescient-filter input choices
                          :key #'car
                          :category :bookmark)
        #'completion-bookmark-detail))
     :test-function
     (lambda (name)
       (assoc name choices :test #'string=))
     :history-symbol 'prompt-for-bookmark)))

(setf (fdefinition 'lem-bookmark::prompt-for-bookmark)
      #'completion-prompt-for-bookmark)
