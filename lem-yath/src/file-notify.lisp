;;;; Bounded Linux file notifications for local visited files.
;;;;
;;;; This deliberately owns a separate inotify descriptor from LSP watching.
;;;; Auto-revert watches are shallow, shared by parent directory, and must not
;;;; destabilize a language server's independently negotiated watch set.

(in-package :lem-yath)

#+sbcl
(require :sb-posix)

(defparameter *file-notify-max-paths* 10000)
(defparameter *file-notify-max-directories* 4096)
(defparameter *file-notify-buffer-size* 65536)

#+linux
(progn
  (sb-alien:define-alien-routine
      ("inotify_init1" %file-notify-inotify-init1)
      sb-alien:int
    (flags sb-alien:int))
  (sb-alien:define-alien-routine
      ("inotify_add_watch" %file-notify-inotify-add-watch)
      sb-alien:int
    (descriptor sb-alien:int)
    (pathname sb-alien:c-string)
    (mask sb-alien:unsigned-int))
  (sb-alien:define-alien-routine
      ("inotify_rm_watch" %file-notify-inotify-rm-watch)
      sb-alien:int
    (descriptor sb-alien:int)
    (watch-descriptor sb-alien:int)))

(defconstant +file-notify-nonblock+ #x00000800)
(defconstant +file-notify-cloexec+ #x00080000)
(defconstant +file-notify-attrib+ #x00000004)
(defconstant +file-notify-close-write+ #x00000008)
(defconstant +file-notify-moved-from+ #x00000040)
(defconstant +file-notify-moved-to+ #x00000080)
(defconstant +file-notify-create+ #x00000100)
(defconstant +file-notify-delete+ #x00000200)
(defconstant +file-notify-delete-self+ #x00000400)
(defconstant +file-notify-move-self+ #x00000800)
(defconstant +file-notify-queue-overflow+ #x00004000)
(defconstant +file-notify-ignored+ #x00008000)
(defconstant +file-notify-only-directory+ #x01000000)

(defconstant +file-notify-watch-mask+
  (logior +file-notify-attrib+
          +file-notify-close-write+
          +file-notify-moved-from+
          +file-notify-moved-to+
          +file-notify-create+
          +file-notify-delete+
          +file-notify-delete-self+
          +file-notify-move-self+
          +file-notify-queue-overflow+
          +file-notify-only-directory+))

(defclass file-notify-service ()
  ((callback :initarg :callback :reader file-notify-callback)
   (descriptor :initform nil :accessor file-notify-descriptor)
   (thread :initform nil :accessor file-notify-thread)
   (running-p :initform nil :accessor file-notify-running-p)
   (lock :initform (bt2:make-lock) :reader file-notify-lock)
   (paths
    :initform (make-hash-table :test 'equal)
    :reader file-notify-paths)
   (directory-descriptors
    :initform (make-hash-table :test 'equal)
    :reader file-notify-directory-descriptors)
   (descriptor-directories
    :initform (make-hash-table)
    :reader file-notify-descriptor-directories)))

(defvar *file-notify-service* nil)

(defun file-notify-path-key (pathname)
  (uiop:native-namestring
   (uiop:ensure-absolute-pathname
    (uiop:ensure-pathname pathname :want-file t))))

(defun file-notify-directory-key (pathname)
  (let* ((directory
           (uiop:ensure-directory-pathname
            (uiop:pathname-directory-pathname
             (uiop:ensure-pathname pathname :want-file t))))
         (native (uiop:native-namestring directory)))
    (if (and (plusp (length native))
             (char/= (char native (1- (length native))) #\/))
        (concatenate 'string native "/")
        native)))

(defun file-notify-symbolic-link-p (pathname)
  #+sbcl
  (handler-case
      (= (logand (sb-posix:stat-mode
                  (sb-posix:lstat (file-notify-path-key pathname)))
                 sb-posix:s-ifmt)
         sb-posix:s-iflnk)
    (sb-posix:syscall-error () nil))
  #-sbcl
  (declare (ignore pathname))
  #-sbcl
  nil)

(defun file-notify-directory-used-p (service directory)
  (loop :for value :being :the :hash-values :of (file-notify-paths service)
        :thereis (string= value directory)))

(defun file-notify-drop-directory (service directory watch-descriptor
                                    &key remove-kernel-watch-p)
  #-linux
  (declare (ignore remove-kernel-watch-p))
  (remhash directory (file-notify-directory-descriptors service))
  (remhash watch-descriptor (file-notify-descriptor-directories service))
  #+linux
  (when (and remove-kernel-watch-p (file-notify-descriptor service))
    (ignore-errors
      (%file-notify-inotify-rm-watch
       (file-notify-descriptor service) watch-descriptor))))

(defun file-notify-add-path (service pathname)
  "Try to watch PATHNAME and return true only when its directory is live."
  #+linux
  (let* ((path (file-notify-path-key pathname))
         (directory (file-notify-directory-key pathname)))
    ;; A parent-directory watch cannot observe mutations made through the
    ;; symlink target.  Match Emacs by leaving such paths on polling fallback.
    (when (file-notify-symbolic-link-p path)
      (file-notify-remove-path service path)
      (return-from file-notify-add-path nil))
    (bt2:with-lock-held ((file-notify-lock service))
      (unless (file-notify-running-p service)
        (return-from file-notify-add-path nil))
      (alexandria:when-let
          ((tracked-directory (gethash path (file-notify-paths service))))
        (if (gethash tracked-directory
                     (file-notify-directory-descriptors service))
            (return-from file-notify-add-path t)
            ;; IN_IGNORED, parent deletion, or a parent move invalidates the
            ;; kernel descriptor but intentionally leaves desired paths.  Drop
            ;; this stale association so reconciliation can reattach it.
            (remhash path (file-notify-paths service))))
      (when (or (>= (hash-table-count (file-notify-paths service))
                    *file-notify-max-paths*)
                (not (uiop:directory-exists-p directory)))
        (return-from file-notify-add-path nil))
      (let ((watch-descriptor
              (gethash directory
                       (file-notify-directory-descriptors service))))
        (unless watch-descriptor
          (when (>= (hash-table-count
                     (file-notify-directory-descriptors service))
                    *file-notify-max-directories*)
            (return-from file-notify-add-path nil))
          (setf watch-descriptor
                (%file-notify-inotify-add-watch
                 (file-notify-descriptor service)
                 directory
                 +file-notify-watch-mask+))
          (when (minusp watch-descriptor)
            (return-from file-notify-add-path nil))
          (setf (gethash directory
                         (file-notify-directory-descriptors service))
                watch-descriptor
                (gethash watch-descriptor
                         (file-notify-descriptor-directories service))
                directory))
        (setf (gethash path (file-notify-paths service)) directory)
        t)))
  #-linux
  (declare (ignore service pathname))
  #-linux
  nil)

(defun file-notify-remove-path (service pathname)
  (let ((path (ignore-errors (file-notify-path-key pathname))))
    (when path
      (bt2:with-lock-held ((file-notify-lock service))
        (alexandria:when-let
            ((directory (gethash path (file-notify-paths service))))
          (remhash path (file-notify-paths service))
          (unless (file-notify-directory-used-p service directory)
            (alexandria:when-let
                ((watch-descriptor
                   (gethash directory
                            (file-notify-directory-descriptors service))))
              (file-notify-drop-directory
               service directory watch-descriptor
               :remove-kernel-watch-p t)))))))
  nil)

(defun file-notify-reconcile (pathnames)
  "Make the current service watch exactly the supported paths in PATHNAMES."
  (alexandria:when-let ((service *file-notify-service*))
    (let ((desired (make-hash-table :test 'equal)))
      (dolist (pathname pathnames)
        (alexandria:when-let
            ((key (ignore-errors (file-notify-path-key pathname))))
          (setf (gethash key desired) pathname)))
      (let ((obsolete nil))
        (bt2:with-lock-held ((file-notify-lock service))
          (loop :for path :being :the :hash-keys
                  :of (file-notify-paths service)
                :unless (gethash path desired)
                  :do (push path obsolete)))
        (dolist (path obsolete)
          (ignore-errors (file-notify-remove-path service path))))
      (loop :for pathname :being :the :hash-values :of desired
            :do (ignore-errors
                  (file-notify-add-path service pathname)))))
  nil)

(defun file-notify-path-watched-p (pathname)
  (alexandria:when-let* ((service *file-notify-service*)
                         (path (ignore-errors
                                 (file-notify-path-key pathname))))
    (and (file-notify-running-p service)
         (bt2:with-lock-held ((file-notify-lock service))
           (alexandria:when-let
               ((directory (gethash path (file-notify-paths service))))
             (not (null
                   (gethash directory
                            (file-notify-directory-descriptors service)))))))))

(defun file-notify-native-u32 (sap offset)
  (sb-sys:sap-ref-32 sap offset))

(defun file-notify-decode-name (buffer start end)
  (let ((nul (position 0 buffer :start start :end end)))
    (when (and nul (> nul start))
      (babel:octets-to-string (subseq buffer start nul)
                              :encoding :utf-8
                              :errorp t))))

(defun file-notify-all-paths (service &optional directory)
  (bt2:with-lock-held ((file-notify-lock service))
    (loop :for path :being :the :hash-keys :of (file-notify-paths service)
            :using (hash-value value)
          :when (or (null directory) (string= value directory))
            :collect path)))

(defun file-notify-event-path (service watch-descriptor name)
  (bt2:with-lock-held ((file-notify-lock service))
    (alexandria:when-let
        ((directory
           (gethash watch-descriptor
                    (file-notify-descriptor-directories service))))
      (let ((path (and name (concatenate 'string directory name))))
        (and path (gethash path (file-notify-paths service)) path)))))

(defun file-notify-invalidate-descriptor (service watch-descriptor)
  (bt2:with-lock-held ((file-notify-lock service))
    (alexandria:when-let
        ((directory
           (gethash watch-descriptor
                    (file-notify-descriptor-directories service))))
      (file-notify-drop-directory service directory watch-descriptor))))

(defun file-notify-parse-events (service buffer count sap)
  (let ((paths (make-hash-table :test 'equal))
        (offset 0))
    (loop :while (<= (+ offset 16) count)
          :for watch-descriptor := (file-notify-native-u32 sap offset)
          :for mask := (file-notify-native-u32 sap (+ offset 4))
          :for name-length := (file-notify-native-u32 sap (+ offset 12))
          :for next := (+ offset 16 name-length)
          :while (<= next count)
          :do
             (cond
               ((not (zerop
                      (logand mask +file-notify-queue-overflow+)))
                (dolist (path (file-notify-all-paths service))
                  (setf (gethash path paths) t)))
               (t
                (let ((name
                        (handler-case
                            (file-notify-decode-name
                             buffer (+ offset 16) next)
                          (error () nil))))
                  (alexandria:when-let
                      ((path
                         (file-notify-event-path
                          service watch-descriptor name)))
                    (setf (gethash path paths) t)))))
             (when (not (zerop
                         (logand mask
                                 (logior +file-notify-delete-self+
                                         +file-notify-move-self+))))
               (alexandria:when-let
                   ((directory
                      (bt2:with-lock-held ((file-notify-lock service))
                        (gethash
                         watch-descriptor
                         (file-notify-descriptor-directories service)))))
                 (dolist (path (file-notify-all-paths service directory))
                   (setf (gethash path paths) t))))
             (when (not (zerop
                         (logand mask
                                 (logior +file-notify-delete-self+
                                         +file-notify-move-self+
                                         +file-notify-ignored+))))
               (file-notify-invalidate-descriptor
                service watch-descriptor))
             (setf offset next))
    (loop :for path :being :the :hash-keys :of paths :collect path)))

(defun file-notify-read-events (service buffer)
  (let ((descriptor (file-notify-descriptor service)))
    (when (sb-sys:wait-until-fd-usable descriptor :input 0.25 nil)
      (sb-sys:with-pinned-objects (buffer)
        (let ((sap (sb-sys:vector-sap buffer)))
          (multiple-value-bind (count errno)
              (sb-unix:unix-read descriptor sap (length buffer))
            (cond
              ((and count (plusp count))
               (file-notify-parse-events service buffer count sap))
              ((or (eql errno sb-unix:eagain)
                   (eql errno sb-unix:eintr))
               nil)
              ((eql count 0) nil)
              (t (error "Auto-revert inotify read failed")))))))))

(defun file-notify-current-service-p (service)
  (and (eq service *file-notify-service*)
       (file-notify-running-p service)))

(defun file-notify-deliver (service paths)
  (when (file-notify-current-service-p service)
    (dolist (path paths)
      (handler-case
          (funcall (file-notify-callback service) path)
        (error (condition)
          (ignore-errors
            (message "External-change notification failed: ~a" condition)))))))

(defun file-notify-disable-after-reader-error (service)
  (setf (file-notify-running-p service) nil
        (file-notify-thread service) nil)
  (alexandria:when-let ((descriptor (file-notify-descriptor service)))
    (ignore-errors (sb-posix:close descriptor))
    (setf (file-notify-descriptor service) nil))
  (bt2:with-lock-held ((file-notify-lock service))
    ;; Keep desired paths so state remains inspectable.  With no live directory
    ;; descriptors every path is immediately eligible for polling fallback.
    (clrhash (file-notify-directory-descriptors service))
    (clrhash (file-notify-descriptor-directories service))))

(defun file-notify-reader-loop (service)
  (let ((buffer (make-array *file-notify-buffer-size*
                            :element-type '(unsigned-byte 8))))
    (handler-case
        (loop :while (file-notify-running-p service)
              :for paths := (file-notify-read-events service buffer)
              :when paths
                :do (send-event
                     (lambda () (file-notify-deliver service paths))))
      (error ()
        (let ((unexpected-p (file-notify-running-p service)))
          (file-notify-disable-after-reader-error service)
          (when unexpected-p
            (send-event
             (lambda ()
               (message
                "File notifications stopped; auto-revert is polling")))))))))

(defun stop-file-notify-service ()
  "Stop this configuration's notification thread and release every watch."
  (alexandria:when-let ((service *file-notify-service*))
    (setf *file-notify-service* nil
          (file-notify-running-p service) nil)
    (alexandria:when-let ((thread (file-notify-thread service)))
      (unless (eq thread (bt2:current-thread))
        (ignore-errors (bt2:join-thread thread)))
      (setf (file-notify-thread service) nil))
    (alexandria:when-let ((descriptor (file-notify-descriptor service)))
      (ignore-errors (sb-posix:close descriptor))
      (setf (file-notify-descriptor service) nil))
    (bt2:with-lock-held ((file-notify-lock service))
      (clrhash (file-notify-paths service))
      (clrhash (file-notify-directory-descriptors service))
      (clrhash (file-notify-descriptor-directories service))))
  nil)

(defun start-file-notify-service (callback)
  "Replace the notification service and return it, or NIL for polling only."
  #-linux
  (declare (ignore callback))
  (stop-file-notify-service)
  #+linux
  (let ((service (make-instance 'file-notify-service :callback callback)))
    (handler-case
        (let ((descriptor
                (%file-notify-inotify-init1
                 (logior +file-notify-nonblock+ +file-notify-cloexec+))))
          (when (minusp descriptor)
            (error "Linux refused an auto-revert inotify descriptor"))
          (setf (file-notify-descriptor service) descriptor
                (file-notify-running-p service) t
                *file-notify-service* service
                (file-notify-thread service)
                (bt2:make-thread
                 (lambda () (file-notify-reader-loop service))
                 :name "lem-yath/file-notify"))
          service)
      (error ()
        (setf (file-notify-running-p service) nil
              (file-notify-thread service) nil)
        (when (eq service *file-notify-service*)
          (setf *file-notify-service* nil))
        (when (file-notify-descriptor service)
          (ignore-errors (sb-posix:close
                          (file-notify-descriptor service)))
          (setf (file-notify-descriptor service) nil))
        nil)))
  #-linux
  nil)

(defun file-notify-service-state ()
  "Return desired paths, kernel directories, and live reader-thread count."
  (alexandria:if-let ((service *file-notify-service*))
    (bt2:with-lock-held ((file-notify-lock service))
      (values (hash-table-count (file-notify-paths service))
              (hash-table-count
               (file-notify-directory-descriptors service))
              (if (and (file-notify-running-p service)
                       (file-notify-thread service))
                  1
                  0)))
    (values 0 0 0)))
