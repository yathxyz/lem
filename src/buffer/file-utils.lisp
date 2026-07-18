(defpackage :lem/buffer/file-utils
  (:use :cl)
  (:import-from :lem/buffer/errors
                :editor-error)
  (:export :expand-file-name
           :tail-of-pathname
           :directory-files
           :list-directory
           :file-size
           :copy-file-or-directory
           :virtual-probe-file
           :with-open-virtual-file
           :*atomic-save*
           :fsync-stream
           :write-file-atomically))
(in-package :lem/buffer/file-utils)

(defun guess-host-name (filename)
  (declare (ignorable filename))
  #+windows
  (ppcre:register-groups-bind (host)
      ("^(\\w:)" filename)
    (pathname-host (parse-namestring host)))
  #-windows
  nil)

(defun parse-filename (filename path)
  (let* ((host (guess-host-name filename))
         (start0 (if host 2 0))
         (split-chars #+windows '(#\/ #\\) #-windows '(#\/)))
    (flet ((split-char-p (c) (member c split-chars)))
      (loop :for start := start0 :then (1+ pos)
            :for pos := (position-if #'split-char-p filename :start start)
            :unless pos
            :do (return
                  (if (= start (length filename))
                      (make-pathname :directory path :host host)
                      (let ((name (subseq filename start)))
                        (make-pathname :name (pathname-name name)
                                       :type (pathname-type name)
                                       :directory path
                                       :host host))))
            :while pos
            :do (let ((name (subseq filename start pos)))
                  (cond ((string= name "."))
                        ((string= name "..")
                         (setf path (butlast path)))
                        ((string= name "~")
                         (setf path (pathname-directory (truename "~/"))))
                        ((string= name "")
                         (setf path (list :absolute)))
                        (t
                         (setf path (append path (list name))))))))))

(defun expand-file-name (filename &optional (directory (uiop:getcwd)))
  (when (pathnamep filename) (setf filename (namestring filename)))
  (let ((pathname (parse-filename filename (pathname-directory directory))))
    (namestring (merge-pathnames pathname directory))))

(defun tail-of-pathname (pathname)
  (let ((pathname (uiop:ensure-absolute-pathname pathname #p"/")))
    (enough-namestring
     pathname
     (if (uiop:directory-pathname-p pathname)
         (uiop:pathname-parent-directory-pathname pathname)
         (uiop:pathname-directory-pathname pathname)))))

(defun probe-file% (x)
  (let ((x2 (probe-file x)))
    (when x2
      (let* ((base "~/")
             (mod (namestring (truename base)))
             (len (length mod)))
        (if (equal (ignore-errors (subseq (namestring x2) 0 len)) mod)
            (make-pathname :defaults (format nil "~A~A" base (subseq (namestring x2) len)))
            x2)))))

(defun virtual-probe-file (pathspec &optional (base-dir pathspec))
  (cond
    ((ppcre:scan "^~/.*" (namestring base-dir)) (probe-file% pathspec))
    (t (probe-file pathspec))))

(defun sort-files (pathnames &key (key #'namestring) (test #'string<))
  "Sort a list of pathnames."
  (sort (copy-list pathnames)
        test :key key))

(defun sort-files-with-method (files &key (sort-method :pathname))
  "Sort files with a sort method, one of :pathname and :mtime."
  (cond
    ((eql sort-method :mtime)
     (sort-files files :test #'> :key #'file-mtime))
    ((eql sort-method :size)
     (sort-files files :test #'> :key #'file-size))
    (t
     (sort-files files))))

(defun directory-files (pathspec)
  (if (uiop:directory-pathname-p pathspec)
      (list (pathname pathspec))
      (or (mapcar (lambda (x) (virtual-probe-file x pathspec))
                  (directory pathspec))
          (list pathspec))))

(defun list-directory (directory &key directory-only (sort-method :pathname))
  (delete nil
          (mapcar (lambda (x) (and (virtual-probe-file x directory) x))
                  (append (sort-files-with-method
                           (copy-list (uiop:subdirectories directory))
                           :sort-method sort-method)
                          (unless directory-only
                            (sort-files-with-method (uiop:directory-files directory)
                                                    :sort-method sort-method))))))

(defun file-size (pathname)
  #+sbcl
  (sb-posix:stat-size (sb-posix:stat pathname))
  #+lispworks
  (system:file-size pathname)
  #+(and (not lispworks) win32)
  (return-from file-size nil)
  #-win32
  (ignore-errors (with-open-file (in pathname) (file-length in))))

(defun file-mtime (pathname)
  "Return the file's last data modification time."
  #+sbcl
  (sb-posix:stat-mtime (sb-posix:stat pathname))
  #-sbcl
  (error "file-utils: file-mtime is not implemented for your implementation."))

(defun copy-file-or-directory (from to)
  (let ((base-dir from))
    (labels ((rec (from to)
               (cond ((uiop:directory-pathname-p from)
                      (dolist (from-file (uiop:directory-files from))
                        (rec from-file (merge-pathnames (enough-namestring from-file base-dir) to)))
                      (dolist (from-dir (uiop:subdirectories from))
                        (rec from-dir
                             (merge-pathnames (uiop:pathname-parent-directory-pathname
                                               (enough-namestring from-dir base-dir))
                                              to))))
                     (t
                      (ensure-directories-exist to)
                      (uiop:copy-file from to)))))
      (rec from to))))

(defparameter *virtual-file-open* nil)

(defun open-virtual-file (filename &key external-format direction element-type)
  (apply #'values
         (or (loop :for f :in *virtual-file-open*
                   :for result := (funcall f filename
                                           :external-format external-format
                                           :element-type element-type
                                           :direction direction)
                   :when result
                   :do (return result))
             (list (apply #'open filename
                          `(:direction ,direction
                            ,@(when (eql direction :output)
                                '(:if-exists :supersede
                                  :if-does-not-exist :create))
                            ,@(when external-format
                                `(:external-format ,external-format))
                            :element-type ,@(if element-type (list element-type) '(character))))))))

(defmacro with-open-virtual-file ((stream filespec &rest options)
                                  &body body)
  (let ((close/ (gensym)))
    `(multiple-value-bind (,stream ,close/)
         (open-virtual-file ,filespec ,@options)
       (unwind-protect
            (multiple-value-prog1
                (progn ,@body))
         (when ,stream
           (funcall (or ,close/ #'close) ,stream))))))

(defvar *atomic-save* t
  "When non-NIL, WRITE-FILE-ATOMICALLY writes through a temporary file in the
target's directory that is fsynced and atomically renamed over the target, so a
crash or error mid-write can never truncate the original. Bind to NIL to force a
direct in-place write.")

(defvar *atomic-random-state* (make-random-state t))

(defun fsync-stream (stream)
  "Best-effort flush of STREAM's buffered data through to stable storage."
  (finish-output stream)
  #+sbcl
  (ignore-errors (sb-posix:fsync (sb-sys:fd-stream-fd stream)))
  (values))

(defun make-atomic-temp-namestring (target)
  "Return a fresh, non-existent temporary file namestring in TARGET's directory."
  (let ((dir (namestring (uiop:pathname-directory-pathname target)))
        (base (file-namestring target)))
    (loop :for candidate := (format nil "~A.#~A.~36R.~D.tmp"
                                    dir
                                    base
                                    (random (expt 36 12) *atomic-random-state*)
                                    #+sbcl (sb-posix:getpid)
                                    #-sbcl 0)
          :unless (probe-file candidate)
          :do (return candidate))))

(defun preserve-file-metadata (source-path temp-path)
  "Copy SOURCE-PATH's permission bits onto TEMP-PATH, and its ownership when
possible. Best effort: ownership changes usually require privilege and are
silently skipped when denied."
  (declare (ignorable source-path temp-path))
  #+sbcl
  (let ((stat (ignore-errors (sb-posix:stat source-path))))
    (when stat
      ;; chown first: an unprivileged chown() clears setuid/setgid, so the
      ;; chmod that restores those bits must come after it.
      (ignore-errors
       (sb-posix:chown temp-path
                       (sb-posix:stat-uid stat)
                       (sb-posix:stat-gid stat)))
      (ignore-errors
       (sb-posix:chmod temp-path (logand (sb-posix:stat-mode stat) #o7777)))))
  (values))

(defun open-atomic-temp-stream (temp element-type external-format)
  (apply #'open temp
         :direction :output
         :if-exists :error
         :if-does-not-exist :create
         :element-type (or element-type 'character)
         (when external-format (list :external-format external-format))))

(defun write-file-in-place (filename writer element-type external-format)
  "Write FILENAME by calling WRITER with a fresh output stream, in place. This is
the legacy, non-atomic path used for virtual files and when *ATOMIC-SAVE* is
NIL."
  (with-open-virtual-file (out filename
                               :element-type element-type
                               :external-format external-format
                               :direction :output)
    (funcall writer out)))

(defun write-file-atomically (filename writer &key element-type external-format)
  "Write FILENAME by calling WRITER (a function of one argument, an open output
stream that WRITER must not close) atomically.

The new contents are written to a temporary file in the target's directory,
fsynced, and renamed over the target, so a crash or error mid-write can never
truncate the original. The target's permission bits are preserved (ownership
too, when possible), and symlinks are followed so the real target is updated
rather than replaced by a regular file.

When *ATOMIC-SAVE* is NIL, or a virtual-file handler claims FILENAME, WRITER's
output is written to FILENAME in place instead. Signals EDITOR-ERROR, leaving
the original untouched, when the target directory is not writable and the atomic
temporary file therefore cannot be created.

The create/write/fsync/metadata/rename/cleanup step sequence is transcribed by
verified/crash-safety.lisp (SPEC-VK VK-6) and tests/pbt/crash-safety-faults.lisp;
any change to the sequence (especially removing the fsync before rename, which
the durability proof depends on) must be mirrored there."
  (when (or (not *atomic-save*) *virtual-file-open*)
    (return-from write-file-atomically
      (write-file-in-place filename writer element-type external-format)))
  (let* ((resolved (uiop:ensure-absolute-pathname
                    (or (uiop:truename* filename) filename)
                    (uiop:getcwd)))
         (temp (make-atomic-temp-namestring resolved))
         (renamed nil))
    (unwind-protect
         (progn
           (handler-case
               (let ((out (open-atomic-temp-stream temp element-type external-format)))
                 (unwind-protect
                      (progn (funcall writer out)
                             (fsync-stream out))
                   (close out)))
             (file-error (e)
               (editor-error "Can't save ~A atomically (directory not writable?): ~A"
                             (namestring resolved) e)))
           (preserve-file-metadata resolved temp)
           (handler-case
               (progn
                 #+sbcl (sb-posix:rename temp (namestring resolved))
                 #-sbcl (rename-file temp resolved))
             (#+sbcl sb-posix:syscall-error #-sbcl file-error (e)
               (editor-error "Can't replace ~A (rename failed): ~A"
                             (namestring resolved) e)))
           (setf renamed t))
      (unless renamed
        (ignore-errors (uiop:delete-file-if-exists temp))))))
