;;;; Linux/SBCL storage, deliberately independent of the editor and user init.
(defpackage :lem-daemon/recovery-store
  (:use :cl)
  (:export :default-directory :new-id :write-record :read-record :list-records
           :discard-record :file-baseline :text-digest :object :field
           :write-private-json :read-private-json :inspect-private-json :list-private-json :map-private-json :ensure-private-directory
           :+maximum-text-length+ :+maximum-record-bytes+))
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
  ;; ancestor. The owner of / is our filesystem trust anchor: it is UID 0 on
  ;; normal Linux and may appear unmapped in a Nix user namespace. Never trust
  ;; an arbitrary unmapped UID merely because of its numeric value.
  (loop with root-owner = (sb-posix:stat-uid (sb-posix:stat "/"))
        for parent = (truename directory)
          then (uiop:pathname-parent-directory-pathname parent)
        for name = (uiop:native-namestring parent)
        for stat = (sb-posix:stat name)
        do (unless (and (kind-p stat sb-posix:s-ifdir)
                        (member (sb-posix:stat-uid stat) (list root-owner (sb-posix:getuid)))
                        (or (zerop (logand (sb-posix:stat-mode stat) #o022))
                            (not (zerop (logand (sb-posix:stat-mode stat) #o1000)))))
             (error "Recovery ancestor is untrusted: ~a (owner ~d, mode ~o)"
                    name (sb-posix:stat-uid stat) (logand (sb-posix:stat-mode stat) #o7777)))
        until (equal name "/")))

(defun ensure-private-directory (directory &key (create t))
  (let* ((directory (uiop:ensure-directory-pathname directory))
         ;; LSTAT of a trailing slash follows the final symlink on Linux.
         (name (string-right-trim "/" (uiop:native-namestring directory))))
    (unless (uiop:absolute-pathname-p directory) (error "Recovery directory must be absolute"))
    (unless (path-stat name)
      (unless create (error "Recovery directory does not exist: ~a" name))
      (let ((parent (uiop:pathname-parent-directory-pathname directory)))
        (unless (probe-file parent) (ensure-private-directory parent))
        (check-directory-ancestors parent))
      (handler-case (sb-posix:mkdir name #o700)
        (sb-posix:syscall-error (condition)
          ;; A concurrent writer may have created the same namespace. Validate
          ;; its ownership/type/permissions below exactly as for any existing leaf.
          (unless (= sb-posix:eexist (sb-posix:syscall-errno condition)) (error condition))))
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

(defun check-json-value (object maximum-depth)
  ;; Restrict encoding to JSON data, before dispatching Yason's generic encoder.
  ;; The lower size bound stops large collections; depth and proper-list checks
  ;; reject cycles without serializing arbitrary Lisp object graphs.
  (let ((size 0))
    (labels ((count-size (n)
               (when (> (incf size n) +maximum-record-bytes+)
                 (error "Recovery record is too large")))
             (walk (value depth)
               (count-size 1)
               (cond
                 ((stringp value) (count-size (length value)))
                 ((member value '(nil t yason:true yason:false :null)))
                 ((integerp value)
                  (when (> (integer-length value) 213) (error "Recovery JSON integer is too large")))
                 ((floatp value)
                  (when (or (sb-ext:float-nan-p value) (sb-ext:float-infinity-p value))
                    (error "JSON numbers must be finite")))
                 ((or (hash-table-p value) (vectorp value) (consp value))
                  (when (> (1+ depth) maximum-depth) (error "Recovery JSON nesting is too deep"))
                  (cond
                    ((hash-table-p value)
                     (maphash (lambda (key item)
                                (unless (stringp key) (error "JSON object keys must be strings"))
                                (count-size (1+ (length key)))
                                (walk item (1+ depth))) value))
                    ((vectorp value) (loop for item across value do (walk item (1+ depth))))
                    (t
                     (unless (list-length value) (error "Circular JSON array"))
                     (dolist (item value) (walk item (1+ depth))))))
                 (t (error "Unsupported JSON value type")))))
      (walk object 0))))

(defun write-private-json (directory id object &key (maximum-depth 16))
  "Durably publish bounded JSON under a validated ID. Callers validate their schema.
Errors after rename report uncertain durability. No Lisp reader is used."
  (unless (typep maximum-depth '(integer 1 64)) (error "Invalid JSON depth bound"))
  (check-json-value object maximum-depth)
  (let* ((directory (ensure-private-directory directory))
         (path (record-path directory id))
         (text (with-output-to-string (out) (yason:encode object out)))
         (octets (babel:string-to-octets text :encoding :utf-8))
         (temporary (merge-pathnames (format nil ".~a.tmp" (new-id)) directory))
         (created nil))
    (when (> (length octets) +maximum-record-bytes+) (error "Recovery record is too large"))
    (check-json-depth text maximum-depth)
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

(defun write-record (directory record)
  (validate-record record)
  (write-private-json directory (field record "id") record :maximum-depth 4))

(defun check-json-depth (text &optional (maximum-depth 4))
  ;; Bound recursive parsing and integer conversion before handing state to Yason.
  ;; Strings contain arbitrary text; no Lisp reader or symbol interning is used.
  (let ((depth 0) (atom-length 0) (quoted nil) (escaped nil))
    (loop for c across text do
      (cond (escaped (setf escaped nil))
            ((and quoted (char= c #\\)) (setf escaped t))
            ((char= c #\") (setf quoted (not quoted) atom-length 0))
            ((not quoted)
             (cond ((find c "[{") (setf atom-length 0)
                    (when (> (incf depth) maximum-depth) (error "Recovery JSON nesting is too deep")))
                   ((find c "]}") (setf atom-length 0) (decf depth))
                   ((or (find c ",:") (find c '(#\Space #\Tab #\Newline #\Return)))
                    (setf atom-length 0))
                   ((> (incf atom-length) 64) (error "Recovery JSON atom is too long"))))))))

(defun read-private-octets (directory id)
  (let* ((directory (ensure-private-directory directory :create nil))
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
          (unless (and (= size (read-sequence bytes stream))
                       (eq :end (read-byte stream nil :end)))
            (error "Recovery record changed size while reading"))
          bytes)))))

(defun parse-private-json (bytes maximum-depth)
  (let ((text (babel:octets-to-string bytes :encoding :utf-8)))
    (check-json-depth text maximum-depth)
    (with-input-from-string (input text)
      (let ((record (yason:parse input :object-as :hash-table)))
        (unless (loop for c = (read-char input nil) while c
                      always (find c '(#\Space #\Tab #\Newline #\Return)))
          (error "Trailing data in recovery record"))
        record))))

(defun read-private-json (directory id &key (maximum-depth 16))
  (unless (typep maximum-depth '(integer 1 64)) (error "Invalid JSON depth bound"))
  (parse-private-json (read-private-octets directory id) maximum-depth))

(defun inspect-private-json (directory id &key (maximum-depth 16))
  "Return parsed JSON, exact-byte SHA256, and NIL or a content-free parse diagnostic.
Unsafe, missing, oversized or incomplete files signal without a fingerprint.
Malformed JSON remains inspectable for deliberate fingerprint-checked cleanup."
  (unless (typep maximum-depth '(integer 1 64)) (error "Invalid JSON depth bound"))
  (let* ((bytes (read-private-octets directory id))
         (fingerprint (ironclad:byte-array-to-hex-string (ironclad:digest-sequence :sha256 bytes))))
    (handler-case (values (parse-private-json bytes maximum-depth) fingerprint nil)
      (error (condition) (values nil fingerprint (princ-to-string (type-of condition)))))))

(defun read-record (directory id)
  (let ((record (validate-record (read-private-json directory id :maximum-depth 4))))
    (unless (equal id (field record "id")) (error "Recovery identifier mismatch"))
    record))

(defun map-private-json (directory function)
  "Call FUNCTION with (ID PATHNAME) for each *.json entry, without reading payloads.
Return the total entry count. IDs are unvalidated filename stems: malformed names,
symlinks and nonregular entries still count; READ-PRIVATE-JSON validates selected
records. Iteration order is unspecified and no ID catalog is retained. A missing
directory returns zero without creating it. Callback errors close the iterator."
  (check-type function function)
  (let ((directory (uiop:ensure-directory-pathname directory)) (count 0))
    (when (probe-file directory)
      (ensure-private-directory directory :create nil)
      (let* ((prefix (uiop:native-namestring directory))
             (entries (sb-posix:opendir prefix)))
        (unwind-protect
             (loop for entry = (sb-posix:readdir entries)
                   until (sb-alien:null-alien entry)
                   for name = (sb-posix:dirent-name entry)
                   when (and (>= (length name) 5)
                             (string= ".json" name :start2 (- (length name) 5)))
                     do (incf count)
                        ;; Native parsing keeps wildcard characters in malformed
                        ;; names literal; they must never become a pathname glob.
                        (funcall function (subseq name 0 (- (length name) 5))
                                 (sb-ext:parse-native-namestring (concatenate 'string prefix name))))
          (sb-posix:closedir entries))))
    count))

(defun list-private-json (directory &key (maximum-depth 16))
  "Return (ID . parsed JSON) entries and (pathname . diagnostic) failures separately.
This reads only, creates no absent directory, and imposes no application schema."
  (unless (typep maximum-depth '(integer 1 64)) (error "Invalid JSON depth bound"))
  (let ((records nil) (failures nil)
        (directory (uiop:ensure-directory-pathname directory)))
    (when (probe-file directory)
      (ensure-private-directory directory :create nil)
      (dolist (path (uiop:directory-files directory "*.json"))
        (handler-case
            (push (cons (pathname-name path)
                        (read-private-json directory (pathname-name path) :maximum-depth maximum-depth)) records)
          (error (condition) (push (cons path (princ-to-string condition)) failures)))))
    (values (sort records #'string< :key #'car) (nreverse failures))))

(defun list-records (directory)
  "Return valid records and, separately, (pathname . diagnostic) failures."
  (let ((records nil) (failures nil)
        (directory (uiop:ensure-directory-pathname directory)))
    (when (probe-file directory)
      (ensure-private-directory directory :create nil)
      (dolist (path (uiop:directory-files directory "*.json"))
        (handler-case (push (read-record directory (pathname-name path)) records)
          (error (condition) (push (cons path (princ-to-string condition)) failures)))))
    (values (sort records #'< :key (lambda (record) (field record "created")))
            (nreverse failures))))

(defun discard-record (directory id)
  (let* ((directory (ensure-private-directory directory :create nil))
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
