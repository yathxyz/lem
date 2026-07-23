;;;; Transaction-safe persistence for Lem's shared project history.

(eval-when (:compile-toplevel :load-toplevel :execute)
  #+sbcl (require :sb-posix))

(in-package :lem-yath)

(defparameter *project-history-entry-limit* 4096)
(defparameter *project-history-entry-size-limit* 4096)
(defparameter *project-history-file-size-limit* (* 4 1024 1024))

(defvar *project-history-process-lock*
  (bt2:make-lock :name "lem-yath/project-history"))

(defun project-history-pathname ()
  (merge-pathnames "history/projects" (lem-home)))

(defun project-history-lock-pathname ()
  (uiop:parse-native-namestring
   (concatenate 'string
                (uiop:native-namestring (project-history-pathname))
                ".lock")))

(defun project-history-lstat (pathname)
  #+sbcl
  (handler-case
      (values (sb-posix:lstat (uiop:native-namestring pathname)) t)
    (sb-posix:syscall-error (condition)
      (if (= (sb-posix:syscall-errno condition) sb-posix:enoent)
          (values nil nil)
          (error condition))))
  #-sbcl
  (error "Safe project history requires the supported SBCL runtime"))

(defun project-history-file-type-p (stat type)
  (= (logand (sb-posix:stat-mode stat) sb-posix:s-ifmt) type))

(defun validate-project-history-directory (directory)
  (multiple-value-bind (stat exists-p) (project-history-lstat directory)
    (unless (and exists-p
                 (project-history-file-type-p stat sb-posix:s-ifdir)
                 (= (sb-posix:stat-uid stat) (sb-posix:getuid))
                 (zerop (logand (sb-posix:stat-mode stat) #o022)))
      (error "Project history directory must be owned by this user and not writable by other users: ~a"
             directory))
    (sb-posix:chmod (uiop:native-namestring directory) #o700)))

(defun validate-project-history-stat (stat pathname)
  (unless (and (project-history-file-type-p stat sb-posix:s-ifreg)
               (= (sb-posix:stat-uid stat) (sb-posix:getuid))
               (zerop (logand (sb-posix:stat-mode stat) #o022)))
    (error "Project history must be an owned regular file not writable by other users: ~a"
           pathname)))

(defun call-with-project-history-lock (function)
  "Serialize one project-history operation across Lem processes."
  (bt2:with-lock-held (*project-history-process-lock*)
    (let* ((pathname (project-history-pathname))
           (directory (uiop:pathname-directory-pathname pathname))
           (descriptor nil))
      (ensure-directories-exist pathname)
      (validate-project-history-directory directory)
      #+sbcl
      (unwind-protect
           (progn
             (setf descriptor
                   (sb-posix:open
                    (uiop:native-namestring (project-history-lock-pathname))
                    (logior sb-posix:o-creat sb-posix:o-rdwr
                            sb-posix:o-nofollow)
                    #o600))
             (sb-posix:fchmod descriptor #o600)
             (validate-project-history-stat
              (sb-posix:fstat descriptor) (project-history-lock-pathname))
             (sb-posix:lockf descriptor sb-posix:f-lock 0)
             (funcall function))
        (when descriptor
          (ignore-errors (sb-posix:lockf descriptor sb-posix:f-ulock 0))
          (ignore-errors (sb-posix:close descriptor))))
      #-sbcl
      (error "Safe project history requires the supported SBCL runtime"))))

(defun project-history-whitespace-p (character)
  (find character '(#\Space #\Tab #\Newline #\Return #\Page)
        :test #'char=))

(defun parse-project-history-text (text)
  "Parse the restricted list-of-strings format emitted by Lem history files."
  (let ((position 0)
        (length (length text))
        (entries '()))
    (labels ((skip-whitespace ()
               (loop :while (and (< position length)
                                 (project-history-whitespace-p
                                  (char text position)))
                     :do (incf position)))
             (next-character ()
               (when (>= position length)
                 (error "Truncated project history"))
               (prog1 (char text position) (incf position)))
             (read-string ()
               (unless (char= (next-character) #\")
                 (error "Project history contains a non-string entry"))
               (with-output-to-string (stream)
                 (loop
                   (let ((character (next-character)))
                     (cond
                       ((char= character #\") (return))
                       ((char= character #\\)
                        (write-char (next-character) stream))
                       (t (write-char character stream)))))))
             (expect-character (expected)
               (unless (char= (next-character) expected)
                 (error "Malformed displaced string in project history")))
             (read-displaced-string ()
               ;; SBCL prints a displaced simple string in this constrained
               ;; form.  Accept it for migration without enabling # dispatch.
               (expect-character #\#)
               (unless (find (next-character) "Aa" :test #'char=)
                 (error "Unsupported dispatch form in project history"))
               (expect-character #\()
               (expect-character #\()
               (let ((start position))
                 (loop :while (and (< position length)
                                   (digit-char-p (char text position)))
                       :do (incf position))
                 (when (= start position)
                   (error "Malformed displaced string length"))
                 (let ((declared-length
                         (parse-integer text :start start :end position)))
                   (when (> declared-length
                            *project-history-entry-size-limit*)
                     (error "Project history contains an oversized path"))
                   (expect-character #\))
                   (skip-whitespace)
                   (let ((base-char-p
                           (and (<= (+ position 9) length)
                                (string-equal "BASE-CHAR" text
                                              :start2 position
                                              :end2 (+ position 9))))
                         (character-p
                           (and (<= (+ position 9) length)
                                (string-equal "CHARACTER" text
                                              :start2 position
                                              :end2 (+ position 9)))))
                     (unless (or base-char-p character-p)
                       (error "Unsupported displaced string element type"))
                     (incf position 9))
                   (skip-whitespace)
                   (expect-character #\.)
                   (skip-whitespace)
                   (let ((value (read-string)))
                     (skip-whitespace)
                     (expect-character #\))
                     (unless (= declared-length (length value))
                       (error "Displaced string length mismatch"))
                     value))))
             (read-entry ()
               (cond
                 ((and (< position length)
                       (char= (char text position) #\"))
                  (read-string))
                 ((and (<= (+ position 2) length)
                       (char= (char text position) #\#)
                       (find (char text (1+ position)) "Aa"
                             :test #'char=))
                  (read-displaced-string))
                 (t
                  (error "Project history contains a non-string entry")))))
      (skip-whitespace)
      ;; Lem's printer represents the empty list as NIL rather than ().
      (when (and (<= (+ position 3) length)
                 (string= "NIL" text
                          :start2 position :end2 (+ position 3)))
        (incf position 3)
        (skip-whitespace)
        (unless (= position length)
          (error "Project history contains trailing data"))
        (return-from parse-project-history-text '()))
      (unless (and (< position length)
                   (char= (next-character) #\())
        (error "Project history is not a list"))
      (loop
        (skip-whitespace)
        (when (>= position length)
          (error "Truncated project history"))
        (when (char= (char text position) #\))
          (incf position)
          (return))
        (when (>= (length entries) *project-history-entry-limit*)
          (error "Project history contains too many entries"))
        (let ((entry (read-entry)))
          (unless (and (plusp (length entry))
                       (<= (length entry)
                           *project-history-entry-size-limit*)
                       (not (find #\Null entry)))
            (error "Project history contains an invalid path"))
          (push entry entries)))
      (skip-whitespace)
      (unless (= position length)
        (error "Project history contains trailing data"))
      (nreverse entries))))

(defun normalize-project-history-entries (entries)
  "Return bounded oldest-to-newest entries with the newest duplicate retained."
  (let ((seen (make-hash-table :test #'equal))
        (result '()))
    (dolist (entry (reverse entries))
      (when (and (stringp entry)
                 (plusp (length entry))
                 (<= (length entry) *project-history-entry-size-limit*)
                 (not (find #\Null entry))
                 (not (gethash entry seen)))
        (setf (gethash entry seen) t)
        (push (copy-seq entry) result)))
    (when (> (length result) *project-history-entry-limit*)
      (setf result (last result *project-history-entry-limit*)))
    result))

(defun read-project-history-file ()
  "Read the owned project history without following a symlink."
  (let ((pathname (project-history-pathname)))
    (multiple-value-bind (stat exists-p) (project-history-lstat pathname)
      (unless exists-p
        (return-from read-project-history-file '()))
      (validate-project-history-stat stat pathname))
    #+sbcl
    (let ((descriptor nil)
          (stream nil))
      (unwind-protect
           (progn
             (setf descriptor
                   (sb-posix:open (uiop:native-namestring pathname)
                                  (logior sb-posix:o-rdonly
                                          sb-posix:o-nofollow)
                                  0))
             (let* ((stat (sb-posix:fstat descriptor))
                    (size (sb-posix:stat-size stat)))
               (validate-project-history-stat stat pathname)
               (when (> size *project-history-file-size-limit*)
                 (error "Project history exceeds the size limit"))
               (setf stream
                     (sb-sys:make-fd-stream
                      descriptor :input t
                      :element-type '(unsigned-byte 8)
                      :buffering :full
                      :name (uiop:native-namestring pathname)))
               (let ((octets (make-array size
                                         :element-type '(unsigned-byte 8))))
                 (unless (= (read-sequence octets stream) size)
                   (error "Project history changed while being read"))
                 (unless (eq (read-byte stream nil :eof) :eof)
                   (error "Project history changed while being read"))
                 (close stream)
                 (setf stream nil descriptor nil)
                 (normalize-project-history-entries
                  (parse-project-history-text
                   (sb-ext:octets-to-string octets
                                            :external-format :utf-8))))))
        (when stream
          (ignore-errors (close stream :abort t))
          (setf descriptor nil))
        (when descriptor
          (ignore-errors (sb-posix:close descriptor)))))
    #-sbcl
    (error "Safe project history requires the supported SBCL runtime")))

(defun serialize-project-history-entries (entries)
  (let* ((entries (normalize-project-history-entries entries))
         (text (with-output-to-string (stream)
                 (let ((*print-readably* t)
                       (*print-pretty* nil))
                   (prin1 entries stream)
                   (terpri stream))))
         (octets
           #+sbcl (sb-ext:string-to-octets text :external-format :utf-8)
           #-sbcl (error "Safe project history requires the supported SBCL runtime")))
    (when (> (length octets) *project-history-file-size-limit*)
      (error "Project history exceeds the size limit"))
    octets))

(defun project-history-temporary-pathname ()
  (uiop:parse-native-namestring
   (format nil "~a.tmp.~d.~16,'0x"
           (uiop:native-namestring (project-history-pathname))
           #+sbcl (sb-posix:getpid)
           #-sbcl 0
           (random (ash 1 60)))))

(defun write-project-history-file (entries)
  "Atomically replace the project history with an owned mode-0600 file."
  (let* ((pathname (project-history-pathname))
         (temporary (project-history-temporary-pathname))
         (octets (serialize-project-history-entries entries))
         (descriptor nil)
         (stream nil))
    (unwind-protect
         (progn
           #+sbcl
           (progn
             (setf descriptor
                   (sb-posix:open
                    (uiop:native-namestring temporary)
                    (logior sb-posix:o-creat sb-posix:o-excl
                            sb-posix:o-wronly sb-posix:o-nofollow)
                    #o600))
             (sb-posix:fchmod descriptor #o600)
             (setf stream
                   (sb-sys:make-fd-stream
                    descriptor :output t
                    :element-type '(unsigned-byte 8)
                    :buffering :full
                    :name (uiop:native-namestring temporary)))
             (write-sequence octets stream)
             (finish-output stream)
             (sb-posix:fsync descriptor)
             (close stream)
             (setf stream nil descriptor nil))
           #-sbcl
           (error "Safe project history requires the supported SBCL runtime")
           (multiple-value-bind (stat exists-p) (project-history-lstat pathname)
             (when exists-p
               (validate-project-history-stat stat pathname)))
           #+sbcl
           (sb-posix:rename (uiop:native-namestring temporary)
                            (uiop:native-namestring pathname))
           #-sbcl
           (error "Safe project history requires the supported SBCL runtime"))
      (when stream
        (ignore-errors (close stream :abort t))
        (setf descriptor nil))
      (when descriptor
        (ignore-errors (sb-posix:close descriptor)))
      (multiple-value-bind (stat exists-p) (project-history-lstat temporary)
        (declare (ignore stat))
        (when exists-p
          (ignore-errors (delete-file temporary)))))))

(defun make-project-history-object ()
  (lem/common/history::%make-history
   :pathname (project-history-pathname)
   :data (make-array 0 :fill-pointer 0 :adjustable t)
   :index 0))

(defun project-history-object ()
  (unless (boundp 'lem-core/commands/project::*projects-history*)
    (setf lem-core/commands/project::*projects-history*
          (make-project-history-object)))
  lem-core/commands/project::*projects-history*)

(defun apply-project-history-entries (entries)
  (let* ((entries (normalize-project-history-entries entries))
         (length (length entries))
         (history (project-history-object)))
    (setf (lem/common/history::history-pathname history)
          (project-history-pathname)
          (lem/common/history::history-data history)
          (make-array length :fill-pointer length :adjustable t
                      :initial-contents entries)
          (lem/common/history::history-index history) length)
    entries))

(defun project-history-refresh ()
  (call-with-project-history-lock
   (lambda ()
     (apply-project-history-entries (read-project-history-file)))))

(defun cached-project-history-entries ()
  (normalize-project-history-entries
   (lem/common/history:history-data-list (project-history-object))))

(defun project-history ()
  "Return shared history, retaining the last good state if a read is unsafe."
  (handler-case
      (project-history-refresh)
    (error () (cached-project-history-entries)))
  (project-history-object))

(defun project-history-entries ()
  "Return a fresh snapshot, or the last good one while storage is unsafe."
  (handler-case
      (project-history-refresh)
    (error () (cached-project-history-entries))))

(defun project-history-add (input)
  "Atomically add or move INPUT to the newest end of shared history."
  (unless (and (stringp input)
               (plusp (length input))
               (<= (length input) *project-history-entry-size-limit*)
               (not (find #\Null input)))
    (error "Invalid project history path"))
  (call-with-project-history-lock
   (lambda ()
     (let* ((disk (read-project-history-file))
            (entries (append (remove input disk :test #'string=)
                             (list (copy-seq input)))))
       (unless (equal entries disk)
         (write-project-history-file entries))
       (apply-project-history-entries entries))))
  input)

(defun project-history-remove (input)
  "Atomically remove INPUT from the latest shared history."
  (call-with-project-history-lock
   (lambda ()
     (let* ((disk (read-project-history-file))
            (entries (remove input disk :test #'string=)))
       (unless (equal entries disk)
         (write-project-history-file entries))
       (apply-project-history-entries entries))))
  input)

(defun safe-core-remember-project (input)
  (let ((input (namestring input)))
    (project-history-add input)
    (message "Saved project: ~A" input)))

(defun safe-core-forget-project (input)
  (project-history-remove input))

(defun safe-core-saved-projects ()
  (project-history-entries))

(defun safe-core-project-unsave ()
  (let ((choice (lem-core/commands/project::prompt-for-project)))
    (project-history-remove choice)
    (message "Project removed: ~A" choice)))

(defun install-safe-project-history-overrides ()
  "Route stock project commands through the transaction-safe writer."
  #+sbcl
  (sb-ext:without-package-locks
    (setf (symbol-function 'lem-core/commands/project::history)
          #'project-history
          (symbol-function 'lem-core/commands/project::remember-project)
          #'safe-core-remember-project
          (symbol-function 'lem-core/commands/project::forget-project)
          #'safe-core-forget-project
          (symbol-function 'lem-core/commands/project::saved-projects)
          #'safe-core-saved-projects
          (symbol-function 'lem-core/commands/project:project-unsave)
          #'safe-core-project-unsave))
  #-sbcl
  (error "Safe project history requires the supported SBCL runtime"))

(install-safe-project-history-overrides)
