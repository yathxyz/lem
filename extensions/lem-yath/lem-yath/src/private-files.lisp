;;;; Private control files shared by integrations, independent of the editor server.

(eval-when (:compile-toplevel :load-toplevel :execute)
  #+sbcl (require :sb-posix))

(in-package :lem-yath)

(defun private-path-stat (pathname)
  #+sbcl
  (handler-case
      (sb-posix:lstat (string-right-trim "/" (uiop:native-namestring pathname)))
    (sb-posix:syscall-error (condition)
      (unless (= sb-posix:enoent (sb-posix:syscall-errno condition))
        (error condition))))
  #-sbcl
  (error "Private control files require SBCL: ~a" pathname))

(defun ensure-private-file-directory (pathname)
  (unless (uiop:absolute-pathname-p pathname)
    (error "Private control paths must be absolute: ~a" pathname))
  (let ((directory (uiop:pathname-directory-pathname pathname)))
    (ensure-directories-exist pathname)
    #+sbcl
    (let ((stat (private-path-stat directory)))
      (unless (and stat (= (sb-posix:stat-uid stat) (sb-posix:getuid))
                   (= (logand (sb-posix:stat-mode stat) sb-posix:s-ifmt)
                      sb-posix:s-ifdir))
        (error "Private control directory must be a user-owned real directory: ~a"
               directory))
      (sb-posix:chmod (uiop:native-namestring directory) #o700))
    #-sbcl (error "Private control files require SBCL")
    directory))

(defun delete-owned-control-file (pathname)
  #+sbcl
  (when pathname
    (let ((stat (private-path-stat pathname)))
      (when (and stat (= (sb-posix:stat-uid stat) (sb-posix:getuid))
                 (= (logand (sb-posix:stat-mode stat) sb-posix:s-ifmt)
                    sb-posix:s-ifreg))
        (sb-posix:unlink (uiop:native-namestring pathname)))))
  #-sbcl (declare (ignore pathname)))

(defun write-private-control-file (pathname text)
  "Publish UTF-8 text atomically, without following an existing link."
  (ensure-private-file-directory pathname)
  #+sbcl
  (let* ((temporary (merge-pathnames
                     (format nil ".control-~d-~36r" (sb-posix:getpid)
                             (random (ash 1 128)))
                     (uiop:pathname-directory-pathname pathname)))
         (descriptor (sb-posix:open
                      (uiop:native-namestring temporary)
                      (logior sb-posix:o-creat sb-posix:o-excl sb-posix:o-wronly)
                      #o600))
         (stream nil))
    (unwind-protect
         (progn
           (setf stream (sb-sys:make-fd-stream descriptor :output t
                                             :external-format :utf-8)
                 descriptor nil)
           (write-string text stream)
           (close stream)
           (setf stream nil)
           (sb-posix:rename (uiop:native-namestring temporary)
                            (uiop:native-namestring pathname)))
      (when stream (close stream :abort t))
      (when descriptor (sb-posix:close descriptor))
      (delete-owned-control-file temporary)))
  #-sbcl (error "Private control files require SBCL"))
