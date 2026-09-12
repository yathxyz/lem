(defpackage :lem-agent/editor-tools
  (:use :cl)
  (:local-nicknames (:agent :lem-agent) (:proposals :lem-buffer-proposals))
  (:export :install-editor-tools :agent-activate-file-buffer))
(in-package :lem-agent/editor-tools)

;; These tools are Linux/SBCL capabilities, matching the managed job runtime.
;; O_PATH inspects a leaf without opening a FIFO/device. Descriptor-relative
;; traversal never resolves a user-supplied symlink, including parent components.
(eval-when (:compile-toplevel :load-toplevel :execute) (require :sb-posix))
(defconstant +o-path+ #o10000000)
(defconstant +o-cloexec+ #o2000000)
(defconstant +at-empty-path+ #x1000)
(defconstant +maximum-file-bytes+ (* 1024 1024))
(defconstant +maximum-fragment-characters+ 4096)

(sb-alien:define-alien-routine ("openat" %openat) sb-alien:int
  (directory sb-alien:int) (name sb-alien:c-string) (flags sb-alien:int))
(sb-alien:define-alien-routine ("statx" %statx) sb-alien:int
  (directory sb-alien:int) (name sb-alien:c-string) (flags sb-alien:int)
  (mask sb-alien:unsigned-int) (result sb-alien:system-area-pointer))

(defun text-p (value maximum &optional (minimum 0))
  (and (stringp value) (<= minimum (length value) maximum)
       (not (find #\Null value))))

(defun path-components (path &key root)
  (unless (and (text-p path 4096) (or root (or (zerop (length path))
                                                             (char/= #\/ (char path 0)))))
    (error "Expected a bounded literal relative path"))
  (let* ((path (if root (string-trim "/" path) path))
         (parts (unless (zerop (length path)) (uiop:split-string path :separator "/"))))
    (unless (and (<= (length parts) 64)
                 (every (lambda (part) (and (plusp (length part))
                                            (not (member part '("." "..") :test #'equal)))) parts))
      (error "Empty, dot, or parent path components are not allowed"))
    parts))

(defun open-entry (parent name &key directory missing)
  (let ((fd (%openat parent name (logior +o-path+ +o-cloexec+ sb-posix:o-nofollow
                                       (if directory sb-posix:o-directory 0)))))
    (cond ((not (minusp fd)) fd)
          ((and missing (= sb-posix:enoent (sb-alien:get-errno))) nil)
          (t (error "Cannot safely open project path component ~s (errno ~d)"
                    name (sb-alien:get-errno))))))

(defun call-with-root (root function)
  (unless (and (text-p root 8192 1) (char= #\/ (char root 0)))
    (error "The session root must be an absolute Linux directory"))
  (let ((fd (sb-posix:open "/" (logior +o-path+ +o-cloexec+ sb-posix:o-directory))))
    (unwind-protect
         (progn
           (dolist (part (path-components root :root t))
             (let ((next (open-entry fd part :directory t)))
               (sb-posix:close fd) (setf fd next)))
           (funcall function fd
                    (concatenate 'string "/" (format nil "~{~a/~}" (path-components root :root t)))))
      (sb-posix:close fd))))

(defun call-with-parent (root path function)
  (let ((parts (path-components path)))
    (call-with-root
     root
     (lambda (root-fd root-name)
       (let ((fd (open-entry root-fd "." :directory t)))
         (unwind-protect
              (progn
                (dolist (part (butlast parts))
                  (let ((next (open-entry fd part :directory t)))
                    (sb-posix:close fd) (setf fd next)))
                (funcall function fd (car (last parts)) root-name))
           (sb-posix:close fd)))))))

(defun descriptor-stamp (fd)
  ;; Linux UAPI struct statx has stable offsets and a 256-byte public layout.
  ;; Nanosecond ctime/mtime plus inode/content checks detect ordinary disk ABA;
  ;; SB-POSIX:STAT alone discards sub-second timestamp resolution.
  (let ((bytes (make-array 256 :element-type '(unsigned-byte 8) :initial-element 0)))
    (sb-sys:with-pinned-objects (bytes)
      (let ((pointer (sb-sys:vector-sap bytes)))
        (unless (zerop (%statx fd "" +at-empty-path+ #x7ff pointer))
          (error "Cannot inspect project file metadata (errno ~d)" (sb-alien:get-errno)))
        (unless (= #x7e3 (logand #x7e3 (sb-sys:sap-ref-32 pointer 0)))
          (error "Project filesystem lacks required file identity metadata"))
        (list (sb-sys:sap-ref-64 pointer #x20) ; inode
              (sb-sys:sap-ref-32 pointer #x88) (sb-sys:sap-ref-32 pointer #x8c) ; device
              (sb-sys:sap-ref-16 pointer #x1c) ; mode
              (sb-sys:sap-ref-64 pointer #x28) ; size
              (sb-sys:signed-sap-ref-64 pointer #x60) (sb-sys:sap-ref-32 pointer #x68) ; ctime
              (sb-sys:signed-sap-ref-64 pointer #x70) (sb-sys:sap-ref-32 pointer #x78)))))) ; mtime

(defstruct file-image path root name content end-of-line stamp digest write-date exists)

(defun normalize-file-text (text)
  "Normalize consistent CRLF/CR files as Lem does; retain mixed endings literally."
  (let ((returns (count #\Return text)) (newlines (count #\Newline text)))
    (cond
      ((and (plusp returns) (zerop newlines))
       (values (substitute #\Newline #\Return text) :cr))
      ((and (plusp returns) (= returns newlines)
            (loop for index below (length text)
                  always (or (char/= #\Return (char text index))
                             (and (< (1+ index) (length text))
                                  (char= #\Newline (char text (1+ index)))))))
       (values (remove #\Return text) :crlf))
      (t (values text :lf)))))

(defun read-regular-descriptor (fd context)
  (let ((before (descriptor-stamp fd)))
    (unless (sb-posix:s-isreg (fourth before))
      (error "File inspection accepts regular files only"))
    (when (> (fifth before) +maximum-file-bytes+)
      (error "Project file exceeds the 1 MiB inspection limit"))
    (let ((input (sb-posix:open (format nil "/proc/self/fd/~d" fd)
                                (logior sb-posix:o-rdonly sb-posix:o-nonblock +o-cloexec+)))
          (result (make-array (1+ +maximum-file-bytes+) :element-type '(unsigned-byte 8)))
          (count 0))
      (unwind-protect
           (progn
             (sb-sys:with-pinned-objects (result)
               (loop
                 (agent:check-operation context)
                 (let ((read (sb-posix:read input (sb-sys:sap+ (sb-sys:vector-sap result) count)
                                           (min 8192 (- (length result) count)))))
                   (when (zerop read) (return))
                   (incf count read)
                   (when (> count +maximum-file-bytes+)
                     (error "Project file grew beyond the 1 MiB inspection limit")))))
             (unless (equal before (descriptor-stamp input))
               (error "Project file changed during inspection"))
             (let* ((bytes (subseq result 0 count))
                    (content (babel:octets-to-string bytes :encoding :utf-8 :errorp t)))
               (when (find #\Null content) (error "Binary file inspection is unsupported"))
               (multiple-value-bind (normalized end-of-line) (normalize-file-text content)
                 (values normalized before (ironclad:byte-array-to-hex-string
                                            (ironclad:digest-sequence :sha256 bytes)) end-of-line))))
        (sb-posix:close input)))))

(defun read-project-file (context path &key (content-p t))
  (agent:check-operation context)
  (call-with-parent
   (agent:operation-root context) path
   (lambda (parent leaf root)
     (unless leaf (error "A file path must not be empty"))
     (let ((fd (open-entry parent leaf :missing t)))
       (unwind-protect
            (if (and fd content-p)
                (multiple-value-bind (content stamp digest end-of-line) (read-regular-descriptor fd context)
                  (make-file-image :path path :root root :name (concatenate 'string root path)
                                   :content content :end-of-line end-of-line :stamp stamp :digest digest :exists t
                                   :write-date (+ 2208988800 (eighth stamp))))
                (progn
                  (when (and fd (not (sb-posix:s-isreg (sb-posix:stat-mode (sb-posix:fstat fd)))))
                    (error "File inspection accepts regular files only"))
                  (make-file-image :path path :root root :name (concatenate 'string root path)
                                   :content (unless fd "") :exists (not (null fd)))))
         (when fd (sb-posix:close fd)))))))

(defun same-file-image-p (left right)
  (and (equal (file-image-name left) (file-image-name right))
       (eql (file-image-exists left) (file-image-exists right))
       (equal (file-image-stamp left) (file-image-stamp right))
       (equal (file-image-digest left) (file-image-digest right))))

(defun entry-kind (fd)
  (let ((mode (sb-posix:stat-mode (sb-posix:fstat fd))))
    (cond ((sb-posix:s-isreg mode) "file") ((sb-posix:s-isdir mode) "directory")
          ((sb-posix:s-islnk mode) "symlink") (t "special"))))

(defun list-project-directory (context path)
  (agent:check-operation context)
  (call-with-parent
   (agent:operation-root context) path
   (lambda (parent leaf root)
     (declare (ignore root))
     (let ((fd (open-entry parent (or leaf ".") :directory t)))
       (unwind-protect
            (let ((directory (sb-posix:opendir (format nil "/proc/self/fd/~d" fd)))
                  (entries '()) (characters (+ 256 (* 6 (length path)))) (truncated nil))
              (unwind-protect
                   (loop for entry = (sb-posix:readdir directory)
                         until (sb-alien:null-alien entry)
                         for name = (sb-posix:dirent-name entry)
                         unless (member name '("." "..") :test #'equal)
                           do (agent:check-operation context)
                              (when (or (= (length entries) 128)
                                        (> (incf characters (+ 64 (* 6 (length name)))) 24000))
                                (setf truncated t) (return))
                              (let ((child (open-entry fd name :missing t)))
                                (when child
                                  (unwind-protect
                                       (push (agent:json-object "name" name "type" (entry-kind child)) entries)
                                    (sb-posix:close child)))))
                (sb-posix:closedir directory))
              (agent:json-object "path" path "entries" (coerce (nreverse entries) 'vector)
                                 "truncated" (if truncated yason:true yason:false)))
         (sb-posix:close fd))))))
