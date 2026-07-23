;;;; Eglot-compatible dynamic workspace/didChangeWatchedFiles delivery.
;;;; Linux inotify keeps project watching event-driven and off the UI thread.

(in-package :lem-yath)

#+sbcl
(require :sb-posix)

(defparameter *lsp-max-file-watches* 10000)
(defparameter *lsp-max-watch-registrations* 64)
(defparameter *lsp-max-watchers-per-registration* 256)
(defparameter *lsp-max-watch-glob-length* 4096)
(defparameter *lsp-inotify-buffer-size* 65536)

#+linux
(progn
  (sb-alien:define-alien-routine ("inotify_init1" %inotify-init1)
      sb-alien:int
    (flags sb-alien:int))
  (sb-alien:define-alien-routine ("inotify_add_watch" %inotify-add-watch)
      sb-alien:int
    (descriptor sb-alien:int)
    (pathname sb-alien:c-string)
    (mask sb-alien:unsigned-int)))

(defconstant +lsp-inotify-nonblock+ #x00000800)
(defconstant +lsp-inotify-cloexec+ #x00080000)
(defconstant +lsp-inotify-attrib+ #x00000004)
(defconstant +lsp-inotify-close-write+ #x00000008)
(defconstant +lsp-inotify-moved-from+ #x00000040)
(defconstant +lsp-inotify-moved-to+ #x00000080)
(defconstant +lsp-inotify-create+ #x00000100)
(defconstant +lsp-inotify-delete+ #x00000200)
(defconstant +lsp-inotify-delete-self+ #x00000400)
(defconstant +lsp-inotify-move-self+ #x00000800)
(defconstant +lsp-inotify-queue-overflow+ #x00004000)
(defconstant +lsp-inotify-ignored+ #x00008000)
(defconstant +lsp-inotify-only-directory+ #x01000000)
(defconstant +lsp-inotify-is-directory+ #x40000000)

(defconstant +lsp-inotify-watch-mask+
  (logior +lsp-inotify-attrib+
          +lsp-inotify-close-write+
          +lsp-inotify-moved-from+
          +lsp-inotify-moved-to+
          +lsp-inotify-create+
          +lsp-inotify-delete+
          +lsp-inotify-delete-self+
          +lsp-inotify-move-self+
          +lsp-inotify-queue-overflow+
          +lsp-inotify-only-directory+))

(defclass lsp-file-watch-spec ()
  ((pattern :initarg :pattern :reader lsp-file-watch-pattern)
   (scanner :initarg :scanner :reader lsp-file-watch-scanner)
   (base-directory :initarg :base-directory
                   :initform nil
                   :reader lsp-file-watch-base-directory)
   (kind :initarg :kind :reader lsp-file-watch-kind)))

(defclass lsp-file-watch-backend ()
  ((workspace :initarg :workspace :reader lsp-file-watch-workspace)
   (specs :initarg :specs :reader lsp-file-watch-specs)
   (descriptor :initform nil :accessor lsp-file-watch-descriptor)
   (thread :initform nil :accessor lsp-file-watch-thread)
   (running-p :initform nil :accessor lsp-file-watch-running-p)
   (watch-descriptors
    :initform (make-hash-table)
    :reader lsp-file-watch-descriptor-directories)
   (directory-watches
    :initform (make-hash-table :test 'equal)
    :reader lsp-file-watch-directory-descriptors)
   (reserved-count :initform 0 :accessor lsp-file-watch-reserved-count)))

(defclass lsp-file-watch-state ()
  ((registrations
    :initform (make-hash-table :test 'equal)
    :reader lsp-file-watch-registrations)
   (backend :initform nil :accessor lsp-file-watch-state-backend)
   (lock :initform (bt2:make-lock) :reader lsp-file-watch-state-lock)))

(defvar *lsp-file-watch-states* (make-hash-table :test 'eq))
(defvar *lsp-file-watch-states-lock* (bt2:make-lock))
(defvar *lsp-file-watch-count* 0)
(defvar *lsp-file-watch-count-lock* (bt2:make-lock))

(defun lsp-file-watch-regex-quote-character (character stream)
  (when (find character "\\.^$|?*+()[]{}" :test #'char=)
    (write-char #\\ stream))
  (write-char character stream))

(defun lsp-file-watch-find-closing (pattern start closing)
  (or (position closing pattern :start start)
      (error "Unclosed LSP file-watch glob delimiter in ~s" pattern)))

(defun lsp-file-watch-range-regex (pattern start end stream)
  (when (= start end)
    (error "Empty LSP file-watch character range in ~s" pattern))
  (write-char #\[ stream)
  (when (char= (char pattern start) #\!)
    (write-char #\^ stream)
    (incf start))
  (when (= start end)
    (error "Empty LSP file-watch character range in ~s" pattern))
  (loop :for index :from start :below end
        :for character := (char pattern index)
        :do (when (find character "/,*{}[]" :test #'char=)
              (error "Invalid character ~s in LSP file-watch range ~s"
                     character pattern))
            (when (char= character #\\)
              (write-char #\\ stream))
            (write-char character stream))
  (write-char #\] stream))

(defun lsp-file-watch-glob-regex-fragment (pattern)
  (with-output-to-string (stream)
    (loop :with length := (length pattern)
          :with index := 0
          :while (< index length)
          :for character := (char pattern index)
          :do
             (cond
               ((char= character #\*)
                (if (and (< (1+ index) length)
                         (char= (char pattern (1+ index)) #\*))
                    (if (and (< (+ index 2) length)
                             (char= (char pattern (+ index 2)) #\/))
                        (progn
                          (write-string "(?:.*/)?" stream)
                          (incf index 3))
                        (progn
                          (write-string ".*" stream)
                          (incf index 2)))
                    (progn
                      (write-string "[^/]*" stream)
                      (incf index))))
               ((char= character #\?)
                (write-string "[^/]" stream)
                (incf index))
               ((char= character #\[)
                (let ((end (lsp-file-watch-find-closing
                            pattern (1+ index) #\])))
                  (lsp-file-watch-range-regex
                   pattern (1+ index) end stream)
                  (setf index (1+ end))))
               ((char= character #\{)
                (let* ((end (lsp-file-watch-find-closing
                             pattern (1+ index) #\}))
                       (body (subseq pattern (1+ index) end))
                       (alternatives (uiop:split-string body :separator ",")))
                  (when (or (null alternatives)
                            (some (lambda (item) (zerop (length item)))
                                  alternatives))
                    (error "Empty LSP file-watch glob alternative in ~s"
                           pattern))
                  (write-string "(?:" stream)
                  (loop :for alternative :in alternatives
                        :for firstp := t :then nil
                        :unless firstp :do (write-char #\| stream)
                        :do (write-string
                             (lsp-file-watch-glob-regex-fragment alternative)
                             stream))
                  (write-char #\) stream)
                  (setf index (1+ end))))
               ((char= character #\})
                (error "Unexpected } in LSP file-watch glob ~s" pattern))
               (t
                (lsp-file-watch-regex-quote-character character stream)
                (incf index))))))

(defun lsp-file-watch-compile-glob (pattern)
  (unless (and (stringp pattern)
               (plusp (length pattern))
               (<= (length pattern) *lsp-max-watch-glob-length*)
               (not (find #\Null pattern)))
    (error "Invalid or oversized LSP file-watch glob"))
  (cl-ppcre:create-scanner
   (format nil "\\A~a\\z" (lsp-file-watch-glob-regex-fragment pattern))))

(defun lsp-file-watch-json-sequence (value limit label)
  (let ((items
          (cond
            ((vectorp value) (coerce value 'list))
            ((listp value) value)
            (t (error "~a must be an array" label)))))
    (when (> (length items) limit)
      (error "~a exceeds its limit of ~d" label limit))
    items))

(defun lsp-file-watch-local-base-directory (value)
  (let ((uri
          (cond
            ((stringp value) value)
            ((hash-table-p value) (gethash "uri" value))
            (t nil))))
    (unless (stringp uri)
      (error "Relative LSP file-watch glob has no local base URI"))
    (let* ((pathname (lem-lsp-base/utils:uri-to-pathname uri))
           (directory (uiop:directory-exists-p pathname)))
      (unless directory
        (error "Relative LSP file-watch base is not a readable directory"))
      (uiop:ensure-directory-pathname (truename directory)))))

(defun lsp-file-watch-parse-spec (watcher)
  (unless (hash-table-p watcher)
    (error "LSP file watcher must be an object"))
  (let* ((glob (gethash "globPattern" watcher))
         (kind (multiple-value-bind (value present-p) (gethash "kind" watcher)
                 (if present-p value 7)))
         pattern
         base-directory)
    (cond
      ((stringp glob) (setf pattern glob))
      ((hash-table-p glob)
       (setf pattern (gethash "pattern" glob)
             base-directory
             (lsp-file-watch-local-base-directory (gethash "baseUri" glob))))
      (t (error "LSP file-watch globPattern must be a string or relative pattern")))
    (unless (and (integerp kind) (<= 1 kind 7))
      (error "LSP file-watch kind must be a nonzero Create/Change/Delete mask"))
    (make-instance 'lsp-file-watch-spec
                   :pattern pattern
                   :scanner (lsp-file-watch-compile-glob pattern)
                   :base-directory base-directory
                   :kind kind)))

(defun lsp-file-watch-parse-registration (registration)
  (unless (hash-table-p registration)
    (error "LSP capability registration must be an object"))
  (let ((id (gethash "id" registration))
        (method (gethash "method" registration))
        (options (gethash "registerOptions" registration)))
    (unless (and (stringp id) (plusp (length id)) (<= (length id) 1024))
      (error "LSP capability registration has an invalid id"))
    (values id method options)))

(defun lsp-file-watch-registration-specs (options)
  (unless (hash-table-p options)
    (error "workspace/didChangeWatchedFiles registration has no options"))
  (let ((watchers
          (lsp-file-watch-json-sequence
           (gethash "watchers" options)
           *lsp-max-watchers-per-registration*
           "LSP file watchers")))
    (when (null watchers)
      (error "workspace/didChangeWatchedFiles registration has no watchers"))
    (mapcar #'lsp-file-watch-parse-spec watchers)))

(defun lsp-file-watch-native-directory (directory)
  (let ((native (uiop:native-namestring
                 (uiop:ensure-directory-pathname directory))))
    (if (and (plusp (length native))
             (char/= (char native (1- (length native))) #\/))
        (concatenate 'string native "/")
        native)))

(defun lsp-file-watch-path-below-p (pathname directory)
  (let ((path (uiop:native-namestring pathname))
        (base (lsp-file-watch-native-directory directory)))
    (alexandria:starts-with-subseq base path)))

(defun lsp-file-watch-symlink-p (pathname)
  (handler-case
      (= (logand (sb-posix:stat-mode
                  (sb-posix:lstat (uiop:native-namestring pathname)))
                 sb-posix:s-ifmt)
         sb-posix:s-iflnk)
    (error () t)))

(defun lsp-file-watch-recursive-directories (root)
  (let ((result nil)
        (count 0))
    (labels ((walk (directory)
               (when (>= count *lsp-max-file-watches*)
                 (error "LSP file-watch directory limit of ~d was reached"
                        *lsp-max-file-watches*))
               (incf count)
               (push directory result)
               (dolist (subdirectory
                         (sort (copy-list (uiop:subdirectories directory))
                               #'string< :key #'uiop:native-namestring))
                 (unless (lsp-file-watch-symlink-p subdirectory)
                   (walk (uiop:ensure-directory-pathname
                          (truename subdirectory)))))))
      (walk (uiop:ensure-directory-pathname (truename root))))
    (nreverse result)))

(defun lsp-file-watch-project-files (root)
  (let ((git-root (project-git-root root)))
    (if (and git-root (uiop:pathname-equal git-root root))
        (git-project-files root)
        (fd-project-files root))))

(defun lsp-file-watch-project-directories (root bases)
  (let ((directories (make-hash-table :test 'equal)))
    (labels ((remember (directory)
               (alexandria:when-let
                   ((existing (uiop:directory-exists-p directory)))
                 (let* ((resolved (uiop:ensure-directory-pathname
                                   (truename existing)))
                        (key (lsp-file-watch-native-directory resolved)))
                   (setf (gethash key directories) resolved)))))
      (remember root)
      (dolist (base bases) (remember base))
      (dolist (relative (lsp-file-watch-project-files root))
        (when (safe-project-relative-path-p relative)
          (let* ((file (project-native-relative-path root relative))
                 (directory (uiop:pathname-directory-pathname file)))
            (when (or (null bases)
                      (some (lambda (base)
                              (lsp-file-watch-path-below-p file base))
                            bases))
              (remember directory)))))
      (loop :for directory :being :the :hash-values :of directories
            :collect directory))))

(defun lsp-file-watch-plan-directories (workspace specs)
  (let* ((root (uiop:ensure-directory-pathname
                (truename (lem-lsp-mode::workspace-root-pathname workspace))))
         (inside-bases nil)
         (outside-bases nil)
         (directories (make-hash-table :test 'equal)))
    (dolist (spec specs)
      (let ((base (lsp-file-watch-base-directory spec)))
        (cond
          ((null base) (pushnew root inside-bases :test #'uiop:pathname-equal))
          ((or (uiop:pathname-equal base root)
               (project-directory-strictly-below-p base root))
           (pushnew base inside-bases :test #'uiop:pathname-equal))
          (t (pushnew base outside-bases :test #'uiop:pathname-equal)))))
    (labels ((remember (directory)
               (let ((key (lsp-file-watch-native-directory directory)))
                 (setf (gethash key directories) directory)
                 (when (> (hash-table-count directories)
                          *lsp-max-file-watches*)
                   (error "LSP file-watch directory limit of ~d was reached"
                          *lsp-max-file-watches*)))))
      (when inside-bases
        (dolist (directory
                  (lsp-file-watch-project-directories root inside-bases))
          (remember directory)))
      (dolist (base outside-bases)
        (dolist (directory (lsp-file-watch-recursive-directories base))
          (remember directory)))
      (sort (loop :for directory :being :the :hash-values :of directories
                  :collect directory)
            #'string< :key #'uiop:native-namestring))))

(defun lsp-file-watch-reserve (count)
  (bt2:with-lock-held (*lsp-file-watch-count-lock*)
    (when (> (+ *lsp-file-watch-count* count) *lsp-max-file-watches*)
      (error "Eglot-compatible global LSP file-watch limit of ~d was reached"
             *lsp-max-file-watches*))
    (incf *lsp-file-watch-count* count)))

(defun lsp-file-watch-release (count)
  (when (plusp count)
    (bt2:with-lock-held (*lsp-file-watch-count-lock*)
      (setf *lsp-file-watch-count*
            (max 0 (- *lsp-file-watch-count* count))))))

(defun lsp-file-watch-add-directory (backend directory &key reserved-p)
  #+linux
  (let* ((directory (uiop:ensure-directory-pathname directory))
         (native (lsp-file-watch-native-directory directory))
         (existing (gethash native
                            (lsp-file-watch-directory-descriptors backend))))
    (or existing
        (progn
          (unless reserved-p (lsp-file-watch-reserve 1))
          (let ((watch-descriptor
                  (%inotify-add-watch
                   (lsp-file-watch-descriptor backend)
                   native
                   +lsp-inotify-watch-mask+)))
            (when (minusp watch-descriptor)
              (unless reserved-p (lsp-file-watch-release 1))
              (error "Linux refused an LSP inotify directory watch"))
            (unless reserved-p
              (incf (lsp-file-watch-reserved-count backend)))
            (setf (gethash watch-descriptor
                           (lsp-file-watch-descriptor-directories backend))
                  directory
                  (gethash native
                           (lsp-file-watch-directory-descriptors backend))
                  watch-descriptor)
            watch-descriptor))))
  #-linux
  (declare (ignore backend directory reserved-p))
  #-linux
  (error "LSP file watching requires Linux inotify"))

(defun lsp-file-watch-drop-descriptor (backend watch-descriptor)
  (alexandria:when-let
      ((directory
         (gethash watch-descriptor
                  (lsp-file-watch-descriptor-directories backend))))
    (remhash watch-descriptor
             (lsp-file-watch-descriptor-directories backend))
    (remhash (lsp-file-watch-native-directory directory)
             (lsp-file-watch-directory-descriptors backend))
    (when (plusp (lsp-file-watch-reserved-count backend))
      (decf (lsp-file-watch-reserved-count backend))
      (lsp-file-watch-release 1))))

(defun lsp-file-watch-native-u32 (sap offset)
  (sb-sys:sap-ref-32 sap offset))

(defun lsp-file-watch-decode-name (buffer start end)
  (let ((nul (position 0 buffer :start start :end end)))
    (when (and nul (> nul start))
      (babel:octets-to-string (subseq buffer start nul)
                              :encoding :utf-8
                              :errorp t))))

(defun lsp-file-watch-child-path (directory name directoryp)
  (let ((pathname
          (uiop:parse-native-namestring
           (concatenate 'string
                        (lsp-file-watch-native-directory directory)
                        name
                        (if directoryp "/" "")))))
    (if directoryp (uiop:ensure-directory-pathname pathname) pathname)))

(defun lsp-file-watch-change-type (mask)
  (cond
    ((not (zerop (logand mask
                         (logior +lsp-inotify-create+
                                 +lsp-inotify-moved-to+))))
     1)
    ((not (zerop (logand mask
                         (logior +lsp-inotify-close-write+
                                 +lsp-inotify-attrib+))))
     2)
    ((not (zerop (logand mask
                         (logior +lsp-inotify-delete+
                                 +lsp-inotify-moved-from+
                                 +lsp-inotify-delete-self+))))
     3)))

(defun lsp-file-watch-parse-events (backend buffer count sap)
  (let ((events nil)
        (offset 0))
    (loop :while (<= (+ offset 16) count)
          :for watch-descriptor := (lsp-file-watch-native-u32 sap offset)
          :for mask := (lsp-file-watch-native-u32 sap (+ offset 4))
          :for name-length := (lsp-file-watch-native-u32 sap (+ offset 12))
          :for next := (+ offset 16 name-length)
          :while (<= next count)
          :do
             (cond
               ((not (zerop (logand mask +lsp-inotify-queue-overflow+)))
                (send-event
                 (lambda ()
                   (message "LSP file-watch queue overflowed; restart the affected workspace"))))
               (t
                (alexandria:when-let
                    ((directory
                       (gethash
                        watch-descriptor
                        (lsp-file-watch-descriptor-directories backend))))
                  (let* ((directoryp
                           (not (zerop
                                 (logand mask +lsp-inotify-is-directory+))))
                         (name
                           (handler-case
                               (lsp-file-watch-decode-name
                                buffer (+ offset 16) next)
                             (error () nil)))
                         (pathname
                           (if name
                               (lsp-file-watch-child-path
                                directory name directoryp)
                               directory))
                         (type (lsp-file-watch-change-type mask)))
                    (when (and directoryp
                               name
                               (= (or type 0) 1)
                               (uiop:directory-exists-p pathname))
                      (handler-case
                          (lsp-file-watch-add-directory backend pathname)
                        (error ()
                          (send-event
                           (lambda ()
                             (message "LSP file-watch directory limit was reached"))))))
                    (when type (push (list pathname type directoryp) events))))))
             (when (not (zerop (logand mask +lsp-inotify-ignored+)))
               (lsp-file-watch-drop-descriptor backend watch-descriptor))
             (setf offset next))
    (nreverse events)))

(defun lsp-file-watch-read-events (backend buffer)
  (let ((descriptor (lsp-file-watch-descriptor backend)))
    (when (sb-sys:wait-until-fd-usable descriptor :input 0.25 nil)
      (sb-sys:with-pinned-objects (buffer)
        (let ((sap (sb-sys:vector-sap buffer)))
          (multiple-value-bind (count errno)
              (sb-unix:unix-read descriptor sap (length buffer))
            (cond
              ((and count (plusp count))
               (lsp-file-watch-parse-events backend buffer count sap))
              ((or (eql errno sb-unix:eagain)
                   (eql errno sb-unix:eintr))
               nil)
              ((eql count 0) nil)
              (t (error "LSP inotify read failed")))))))))

(defun lsp-file-watch-candidate (spec pathname directoryp)
  (let* ((native (uiop:native-namestring pathname))
         (native (if (and directoryp
                          (plusp (length native))
                          (char/= (char native (1- (length native))) #\/))
                     (concatenate 'string native "/")
                     native))
         (base (lsp-file-watch-base-directory spec)))
    (cond
      ((null base) native)
      ((lsp-file-watch-path-below-p pathname base)
       (subseq native (length (lsp-file-watch-native-directory base)))))))

(defun lsp-file-watch-matches-p (backend pathname type directoryp)
  (let ((kind-bit (ash 1 (1- type))))
    (some
     (lambda (spec)
       (and (not (zerop (logand kind-bit (lsp-file-watch-kind spec))))
            (alexandria:when-let
                ((candidate
                   (lsp-file-watch-candidate spec pathname directoryp)))
              (cl-ppcre:scan (lsp-file-watch-scanner spec) candidate))))
     (lsp-file-watch-specs backend))))

(defun lsp-file-watch-path-key (pathname)
  (uiop:native-namestring (uiop:ensure-absolute-pathname pathname)))

(defun lsp-file-watch-open-buffer-p (workspace pathname)
  (let ((key (lsp-file-watch-path-key pathname)))
    (some
     (lambda (buffer)
       (alexandria:when-let ((filename (buffer-filename buffer)))
         (or (ignore-errors (uiop:pathname-equal filename pathname))
             (string= (lsp-file-watch-path-key filename) key))))
     (lem-lsp-mode::workspace-buffers workspace))))

(defun lsp-file-watch-current-backend-p (workspace backend)
  (let ((state
          (bt2:with-lock-held (*lsp-file-watch-states-lock*)
            (gethash workspace *lsp-file-watch-states*))))
    (and state
         (bt2:with-lock-held ((lsp-file-watch-state-lock state))
           (eq backend (lsp-file-watch-state-backend state))))))

(defun lsp-file-watch-deliver-events (backend events)
  (let ((workspace (lsp-file-watch-workspace backend)))
    (when (and (lsp-file-watch-current-backend-p workspace backend)
               (not (member (lem-lsp-mode::workspace-state workspace)
                            '(:stopping :disposed))))
      (let ((seen (make-hash-table :test 'equal))
            (changes nil))
        (dolist (event events)
          (destructuring-bind (pathname type directoryp) event
            (declare (ignore directoryp))
            (let ((key (cons type (lsp-file-watch-path-key pathname))))
              (when (and (not (gethash key seen))
                         (not (lsp-file-watch-open-buffer-p
                               workspace pathname)))
                (setf (gethash key seen) t)
                (push
                 (make-instance 'lsp:file-event
                                :uri (lem-lsp-mode::pathname-to-uri pathname)
                                :type type)
                 changes)))))
        (when changes
          (ignore-errors
            (lem-language-client/request:request
             (lem-lsp-mode::workspace-client workspace)
             (make-instance 'lsp:workspace/did-change-watched-files)
             (make-instance 'lsp:did-change-watched-files-params
                            :changes (coerce (nreverse changes) 'vector)))))))))

(defun lsp-file-watch-reader-loop (backend)
  (let ((buffer (make-array *lsp-inotify-buffer-size*
                            :element-type '(unsigned-byte 8))))
    (handler-case
        (loop :while (lsp-file-watch-running-p backend)
              :for events := (lsp-file-watch-read-events backend buffer)
              :when events
                :do (let ((events
                            (remove-if-not
                             (lambda (event)
                               (destructuring-bind
                                   (pathname type directoryp) event
                                 (lsp-file-watch-matches-p
                                  backend pathname type directoryp)))
                             events)))
                      (when events
                        (send-event
                         (lambda ()
                           (lsp-file-watch-deliver-events backend events))))))
      (error ()
        (let ((unexpected-p (lsp-file-watch-running-p backend)))
          (setf (lsp-file-watch-running-p backend) nil)
          (when unexpected-p
            (send-event
             (lambda ()
               (message
                "LSP file watching stopped after an inotify error")))))))))

(defun lsp-file-watch-stop-backend (backend)
  (when backend
    (setf (lsp-file-watch-running-p backend) nil)
    (alexandria:when-let ((thread (lsp-file-watch-thread backend)))
      (ignore-errors (bt2:join-thread thread))
      (setf (lsp-file-watch-thread backend) nil))
    (alexandria:when-let ((descriptor (lsp-file-watch-descriptor backend)))
      (ignore-errors (sb-posix:close descriptor))
      (setf (lsp-file-watch-descriptor backend) nil))
    (lsp-file-watch-release (lsp-file-watch-reserved-count backend))
    (setf (lsp-file-watch-reserved-count backend) 0)
    (clrhash (lsp-file-watch-descriptor-directories backend))
    (clrhash (lsp-file-watch-directory-descriptors backend))))

(defun lsp-file-watch-start-backend (workspace specs)
  #+linux
  (let* ((directories (lsp-file-watch-plan-directories workspace specs))
         (backend (make-instance 'lsp-file-watch-backend
                                 :workspace workspace
                                 :specs specs)))
    (when (null directories)
      (error "LSP file-watch registration resolved to no directories"))
    (lsp-file-watch-reserve (length directories))
    (setf (lsp-file-watch-reserved-count backend) (length directories))
    (handler-case
        (progn
          (let ((descriptor
                  (%inotify-init1
                   (logior +lsp-inotify-nonblock+ +lsp-inotify-cloexec+))))
            (when (minusp descriptor)
              (error "Linux refused an LSP inotify descriptor"))
            (setf (lsp-file-watch-descriptor backend) descriptor))
          (dolist (directory directories)
            (lsp-file-watch-add-directory backend directory :reserved-p t))
          (setf (lsp-file-watch-running-p backend) t
                (lsp-file-watch-thread backend)
                (bt2:make-thread
                 (lambda () (lsp-file-watch-reader-loop backend))
                 :name "lem-yath/lsp-file-watch"))
          backend)
      (error (condition)
        (lsp-file-watch-stop-backend backend)
        (error condition))))
  #-linux
  (declare (ignore workspace specs))
  #-linux
  (error "LSP file watching requires Linux inotify"))

(defun lsp-file-watch-all-specs (state)
  (loop :for specs :being :the :hash-values
          :of (lsp-file-watch-registrations state)
        :append (copy-list specs)))

(defun lsp-file-watch-rebuild (workspace state)
  (lsp-file-watch-stop-backend (lsp-file-watch-state-backend state))
  (setf (lsp-file-watch-state-backend state) nil)
  (alexandria:when-let ((specs (lsp-file-watch-all-specs state)))
    (setf (lsp-file-watch-state-backend state)
          (lsp-file-watch-start-backend workspace specs))))

(defun lsp-file-watch-state-for-workspace (workspace)
  (bt2:with-lock-held (*lsp-file-watch-states-lock*)
    (or (gethash workspace *lsp-file-watch-states*)
        (setf (gethash workspace *lsp-file-watch-states*)
              (make-instance 'lsp-file-watch-state)))))

(defun lsp-register-file-watch (workspace id options)
  (let ((state (lsp-file-watch-state-for-workspace workspace))
        (specs (lsp-file-watch-registration-specs options)))
    (bt2:with-lock-held ((lsp-file-watch-state-lock state))
      (let ((registrations (lsp-file-watch-registrations state)))
        (unless (or (gethash id registrations)
                    (< (hash-table-count registrations)
                       *lsp-max-watch-registrations*))
          (error "LSP file-watch registration limit of ~d was reached"
                 *lsp-max-watch-registrations*))
        (multiple-value-bind (previous present-p)
            (gethash id registrations)
          (setf (gethash id registrations) specs)
          (handler-case
              (lsp-file-watch-rebuild workspace state)
            (error (condition)
              (if present-p
                  (setf (gethash id registrations) previous)
                  (remhash id registrations))
              (ignore-errors (lsp-file-watch-rebuild workspace state))
              (error condition))))))))

(defun lsp-unregister-file-watch (workspace id)
  (let ((state
          (bt2:with-lock-held (*lsp-file-watch-states-lock*)
            (gethash workspace *lsp-file-watch-states*))))
    (when state
      (bt2:with-lock-held ((lsp-file-watch-state-lock state))
        (let ((registrations (lsp-file-watch-registrations state)))
          (multiple-value-bind (previous present-p)
              (gethash id registrations)
            (when present-p
              (remhash id registrations)
              (handler-case
                  (lsp-file-watch-rebuild workspace state)
                (error (condition)
                  (setf (gethash id registrations) previous)
                  (ignore-errors (lsp-file-watch-rebuild workspace state))
                  (error condition))))))))))

(defun lsp-register-capabilities (workspace params)
  (unless (hash-table-p params)
    (error "client/registerCapability parameters must be an object"))
  (dolist (registration
            (lsp-file-watch-json-sequence
             (gethash "registrations" params)
             *lsp-max-watch-registrations*
             "LSP capability registrations"))
    (multiple-value-bind (id method options)
        (lsp-file-watch-parse-registration registration)
      (when (string= method "workspace/didChangeWatchedFiles")
        (lsp-register-file-watch workspace id options))))
  nil)

(defun lsp-unregister-capabilities (workspace params)
  (unless (hash-table-p params)
    (error "client/unregisterCapability parameters must be an object"))
  (dolist (unregistration
            (lsp-file-watch-json-sequence
             (gethash "unregisterations" params)
             *lsp-max-watch-registrations*
             "LSP capability unregistrations"))
    (multiple-value-bind (id method options)
        (lsp-file-watch-parse-registration unregistration)
      (declare (ignore options))
      (when (string= method "workspace/didChangeWatchedFiles")
        (lsp-unregister-file-watch workspace id))))
  nil)

(defun lsp-stop-file-watches (workspace)
  (let ((state
          (bt2:with-lock-held (*lsp-file-watch-states-lock*)
            (prog1 (gethash workspace *lsp-file-watch-states*)
              (remhash workspace *lsp-file-watch-states*)))))
    (when state
      (bt2:with-lock-held ((lsp-file-watch-state-lock state))
        (lsp-file-watch-stop-backend
         (lsp-file-watch-state-backend state))
        (setf (lsp-file-watch-state-backend state) nil)
        (clrhash (lsp-file-watch-registrations state)))))
  nil)

(defun lsp-file-watch-workspace-state (workspace)
  "Return registration, kernel-watch, live-thread, and global-watch counts."
  (let ((state
          (bt2:with-lock-held (*lsp-file-watch-states-lock*)
            (gethash workspace *lsp-file-watch-states*))))
    (if (null state)
        (values 0 0 0
                (bt2:with-lock-held (*lsp-file-watch-count-lock*)
                  *lsp-file-watch-count*))
        (bt2:with-lock-held ((lsp-file-watch-state-lock state))
          (let ((backend (lsp-file-watch-state-backend state)))
            (values
             (hash-table-count (lsp-file-watch-registrations state))
             (if backend
                 (hash-table-count
                  (lsp-file-watch-descriptor-directories backend))
                 0)
             (if (and backend
                      (lsp-file-watch-running-p backend)
                      (lsp-file-watch-thread backend))
                 1
                 0)
             (bt2:with-lock-held (*lsp-file-watch-count-lock*)
               *lsp-file-watch-count*)))))))
