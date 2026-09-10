;;;; Linux/SBCL storage, deliberately independent of the editor and user init.
(defpackage :lem-daemon/recovery-store
  (:use :cl)
  (:export :default-directory :new-id :write-record :read-record :list-records
           :discard-record :file-baseline :text-digest :object :field
           :+maximum-text-length+))
(in-package :lem-daemon/recovery-store)

(eval-when (:compile-toplevel :load-toplevel :execute)
  #+(and sbcl linux) (require :sb-posix)
  #-(and sbcl linux) (error "Durable Lem recovery currently requires SBCL on Linux"))

(defconstant +maximum-text-length+ (* 2 1024 1024))
(defconstant +maximum-record-bytes+ (* 16 1024 1024))
(defconstant +maximum-baseline-bytes+ (* 16 1024 1024))

(defun object (&rest fields)
  (let ((result (make-hash-table :test #'equal)))
    (loop for (key value) on fields by #'cddr do (setf (gethash key result) value))
    result))

(defun field (record key) (gethash key record))

(defun safe-name-p (name)
  (and (stringp name) (<= 1 (length name) 64)
       (every (lambda (c) (or (find c "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
                              (find c "-_"))) name)))

(defun default-directory (&optional (server-name "default"))
  (unless (safe-name-p server-name) (error "Invalid recovery namespace"))
  (merge-pathnames (format nil "lem/recovery/~a/" server-name)
                   (uiop:ensure-directory-pathname
                    (or (uiop:getenvp "XDG_STATE_HOME")
                        (merge-pathnames ".local/state/" (user-homedir-pathname))))))

(defun new-id ()
  (ironclad:byte-array-to-hex-string (ironclad:random-data 16)))

(defun valid-id-p (id)
  (and (stringp id) (= 32 (length id))
       (every (lambda (c) (find c "0123456789abcdef")) id)))

(defun record-path (directory id)
  (unless (valid-id-p id) (error "Invalid recovery record identifier"))
  (merge-pathnames (format nil "~a.json" id) (uiop:ensure-directory-pathname directory)))

(defun path-stat (path)
  (handler-case (sb-posix:lstat (uiop:native-namestring path))
    (sb-posix:syscall-error (condition)
      (unless (= (sb-posix:syscall-errno condition) sb-posix:enoent) (error condition)))))

(defun kind-p (stat kind)
  (and stat (= (logand (sb-posix:stat-mode stat) sb-posix:s-ifmt) kind)))

(defun check-directory-ancestors (directory)
  ;; Private leaf permissions are insufficient if another user can replace an
  ;; ancestor. Resolve parent symlinks and require a chain that other users cannot
  ;; rename. Root-owned sticky /tmp is allowed; arbitrary shared writers are not.
  (loop for parent = (truename directory)
          then (uiop:pathname-parent-directory-pathname parent)
        for name = (uiop:native-namestring parent)
        for stat = (sb-posix:stat name)
        do (unless (and (kind-p stat sb-posix:s-ifdir)
                        (member (sb-posix:stat-uid stat) (list 0 (sb-posix:getuid)))
                        (or (zerop (logand (sb-posix:stat-mode stat) #o022))
                            (not (zerop (logand (sb-posix:stat-mode stat) #o1000)))))
             (error "Recovery ancestor can be replaced by another user: ~a" name))
        until (equal name "/")))

(defun ensure-private-directory (directory)
  (let* ((directory (uiop:ensure-directory-pathname directory))
         ;; LSTAT of a trailing slash follows the final symlink on Linux.
         (name (string-right-trim "/" (uiop:native-namestring directory))))
    (unless (uiop:absolute-pathname-p directory) (error "Recovery directory must be absolute"))
    (unless (path-stat name)
      (let ((parent (uiop:pathname-parent-directory-pathname directory)))
        (unless (probe-file parent) (ensure-private-directory parent))
        (check-directory-ancestors parent))
      (sb-posix:mkdir name #o700)
      (fsync-directory (uiop:pathname-parent-directory-pathname directory)))
    (let ((stat (path-stat name)))
      (unless (and (kind-p stat sb-posix:s-ifdir)
                   (= (sb-posix:stat-uid stat) (sb-posix:getuid))
                   (zerop (logand (sb-posix:stat-mode stat) #o077)))
        (error "Recovery directory must be a private, owned directory: ~a" name)))
    (check-directory-ancestors (uiop:pathname-parent-directory-pathname directory))
    directory))

(defun check-private-file-stat (stat path)
  (unless (and (kind-p stat sb-posix:s-ifreg)
               (= (sb-posix:stat-uid stat) (sb-posix:getuid))
               (= (sb-posix:stat-nlink stat) 1)
               (zerop (logand (sb-posix:stat-mode stat) #o077)))
    (error "Recovery file is not a private, owned regular file: ~a" path)))

(defun fsync-directory (directory)
  (let ((fd (sb-posix:open (uiop:native-namestring directory)
                           (logior sb-posix:o-rdonly sb-posix:o-directory))))
    (unwind-protect (sb-posix:fsync fd) (sb-posix:close fd))))

(defun bounded-string-p (value maximum)
  (and (stringp value) (<= (length value) maximum)))

(defun valid-baseline-p (value)
  (or (member value '("missing" "unknown") :test #'equal)
      (and (stringp value) (= (length value) 64)
           (every (lambda (c) (find c "0123456789abcdef")) value))))

(defun validate-record (record)
  (unless (and (hash-table-p record)
               (= (hash-table-count record) 8)
               (loop for key being the hash-keys of record
                     always (member key '("version" "id" "name" "filename" "baseline"
                                          "created" "point" "text") :test #'equal))
               (eql (field record "version") 1)
               (valid-id-p (field record "id"))
               (bounded-string-p (field record "name") 4096)
               (or (null (field record "filename"))
                   (and (bounded-string-p (field record "filename") 8192)
                        (uiop:absolute-pathname-p (field record "filename"))))
               (valid-baseline-p (field record "baseline"))
               (typep (field record "created") '(integer 0))
               (bounded-string-p (field record "text") +maximum-text-length+)
               (typep (field record "point") '(integer 0))
               (<= (field record "point") (length (field record "text"))))
    (error "Invalid recovery record schema"))
  record)

(defun write-record (directory record)
  "Durably publish one bounded JSON record. Errors leave the preceding record intact
until rename; a directory-fsync error after rename is reported as uncertain durability."
  (validate-record record)
  (let* ((directory (ensure-private-directory directory))
         (path (record-path directory (field record "id")))
         (octets (babel:string-to-octets
                  (with-output-to-string (out) (yason:encode record out))
                  :encoding :utf-8))
         (temporary (merge-pathnames (format nil ".~a.tmp" (new-id)) directory))
         (created nil))
    (when (> (length octets) +maximum-record-bytes+) (error "Recovery record is too large"))
    (when (path-stat path) (check-private-file-stat (path-stat path) path))
    (unwind-protect
         (let ((fd (sb-posix:open (uiop:native-namestring temporary)
                                 (logior sb-posix:o-wronly sb-posix:o-creat
                                         sb-posix:o-excl sb-posix:o-nofollow)
                                 #o600)))
           (setf created t)
           (with-open-stream (stream (sb-sys:make-fd-stream fd :output t
                                                          :element-type '(unsigned-byte 8)
                                                          :auto-close t))
             (write-sequence octets stream)
             (finish-output stream)
             (sb-posix:fsync fd))
           (sb-posix:rename (uiop:native-namestring temporary) (uiop:native-namestring path))
           (setf created nil)
           (fsync-directory directory)
           path)
      (when created (uiop:delete-file-if-exists temporary)))))

(defun check-json-depth (text)
  ;; Bound recursive parsing and integer conversion before handing state to Yason.
  ;; Strings contain arbitrary text; no Lisp reader or symbol interning is used.
  (let ((depth 0) (atom-length 0) (quoted nil) (escaped nil))
    (loop for c across text do
      (cond (escaped (setf escaped nil))
            ((and quoted (char= c #\\)) (setf escaped t))
            ((char= c #\") (setf quoted (not quoted) atom-length 0))
            ((not quoted)
             (cond ((find c "[{") (setf atom-length 0)
                    (when (> (incf depth) 4) (error "Recovery JSON nesting is too deep")))
                   ((find c "]}") (setf atom-length 0) (decf depth))
                   ((or (find c ",:") (find c '(#\Space #\Tab #\Newline #\Return)))
                    (setf atom-length 0))
                   ((> (incf atom-length) 64) (error "Recovery JSON atom is too long"))))))))

(defun read-record (directory id)
  (let* ((directory (ensure-private-directory directory))
         (path (record-path directory id))
         (fd (sb-posix:open (uiop:native-namestring path)
                            (logior sb-posix:o-rdonly sb-posix:o-nofollow sb-posix:o-nonblock))))
    (with-open-stream (stream (sb-sys:make-fd-stream fd :input t
                                                   :element-type '(unsigned-byte 8)
                                                   :auto-close t))
      (let* ((stat (sb-posix:fstat fd))
             (size (sb-posix:stat-size stat)))
        (check-private-file-stat stat path)
        (unless (<= size +maximum-record-bytes+) (error "Recovery record is too large"))
        (let ((bytes (make-array size :element-type '(unsigned-byte 8))))
          (unless (= size (read-sequence bytes stream)) (error "Truncated recovery record"))
          (let ((text (babel:octets-to-string bytes :encoding :utf-8)))
            (check-json-depth text)
            (with-input-from-string (input text)
              (let ((record (validate-record (yason:parse input :object-as :hash-table))))
                (unless (loop for c = (read-char input nil) while c
                              always (find c '(#\Space #\Tab #\Newline #\Return)))
                  (error "Trailing data in recovery record"))
                (unless (equal id (field record "id")) (error "Recovery identifier mismatch"))
                record))))))))

(defun list-records (directory)
  "Return valid records and, separately, (pathname . diagnostic) failures."
  (let ((records nil) (failures nil)
        (directory (uiop:ensure-directory-pathname directory)))
    (when (probe-file directory)
      (ensure-private-directory directory)
      (dolist (path (uiop:directory-files directory "*.json"))
        (handler-case (push (read-record directory (pathname-name path)) records)
          (error (condition) (push (cons path (princ-to-string condition)) failures)))))
    (values (sort records #'< :key (lambda (record) (field record "created")))
            (nreverse failures))))

(defun discard-record (directory id)
  (let* ((directory (ensure-private-directory directory))
         (path (record-path directory id))
         (stat (path-stat path)))
    (when stat
      (check-private-file-stat stat path)
      (sb-posix:unlink (uiop:native-namestring path))
      (fsync-directory directory)
      t)))

(defun text-digest (text)
  (ironclad:byte-array-to-hex-string
   (ironclad:digest-sequence :sha256 (babel:string-to-octets text :encoding :utf-8))))

(defun file-baseline (filename)
  "A bounded raw-file digest, MISSING, or UNKNOWN. Never block on a FIFO/device."
  (handler-case
      (let ((stat (path-stat filename)))
        (unless stat (return-from file-baseline "missing"))
        (unless (and (kind-p stat sb-posix:s-ifreg)
                     (<= (sb-posix:stat-size stat) +maximum-baseline-bytes+))
          (return-from file-baseline "unknown"))
        (let ((fd (sb-posix:open (uiop:native-namestring filename)
                                 (logior sb-posix:o-rdonly sb-posix:o-nofollow sb-posix:o-nonblock))))
          (with-open-stream (stream (sb-sys:make-fd-stream fd :input t
                                                         :element-type '(unsigned-byte 8)
                                                         :auto-close t))
            (let ((opened (sb-posix:fstat fd)))
              (unless (and (kind-p opened sb-posix:s-ifreg)
                           (<= (sb-posix:stat-size opened) +maximum-baseline-bytes+))
                (return-from file-baseline "unknown"))
              (let* ((size (sb-posix:stat-size opened))
                     (bytes (make-array size :element-type '(unsigned-byte 8))))
                (unless (and (= size (read-sequence bytes stream))
                             (eq :end (read-byte stream nil :end)))
                  (return-from file-baseline "unknown"))
                (ironclad:byte-array-to-hex-string (ironclad:digest-sequence :sha256 bytes)))))))
    (error () "unknown")))
