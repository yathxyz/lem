;;;; Configured org-download clipboard and URL-yank workflows.
;;;;
;;;; The active Emacs profile stores every capture directly in
;;;; $WORKDIR/media/ (no heading subdirectory).  Transfers here are deliberately
;;;; direct-argv, bounded, image-signature checked, and committed with the Org
;;;; link as one retained buffer transaction.

(in-package :lem-yath)

(defparameter *org-download-byte-limit* (* 64 1024 1024)
  "Largest image accepted by one configured Org download command.")

(defparameter *org-download-process-timeout* 30
  "Hard timeout in seconds for clipboard and network image readers.")

(defvar *org-download-now-function* #'get-universal-time
  "Clock used for configured file names and #+DOWNLOADED annotations.")

(defun org-download-byte-limit-label ()
  (cond
    ((zerop (mod *org-download-byte-limit* 1048576))
     (format nil "~:d MiB" (/ *org-download-byte-limit* 1048576)))
    ((zerop (mod *org-download-byte-limit* 1024))
     (format nil "~:d KiB" (/ *org-download-byte-limit* 1024)))
    (t
     (format nil "~:d bytes" *org-download-byte-limit*))))

(defun org-download-media-directory ()
  "Return the configured, startup-fixed $WORKDIR/media/ directory."
  (uiop:ensure-directory-pathname (merge-pathnames "media/" (workdir))))

(defun org-download-require-org-buffer ()
  (unless (eq (buffer-major-mode (current-buffer)) 'org-mode)
    (editor-error "Org download is only available in an Org buffer"))
  (when (buffer-read-only-p (current-buffer))
    (editor-error "The Org buffer is read-only")))

(defun org-download-control-character-p (character)
  (let ((code (char-code character)))
    (or (< code 32) (= code 127))))

(defun org-download-parse-url (text)
  "Parse one bounded HTTP(S) or local file URL from TEXT."
  (unless (stringp text)
    (editor-error "The kill ring does not contain a URL"))
  (let ((url (string-right-trim '(#\Newline #\Return) text)))
    (unless (and (plusp (length url))
                 (<= (length url) 8192)
                 (notany #'org-download-control-character-p url))
      (editor-error "The kill ring does not contain a valid URL"))
    (let ((uri
            (handler-case (quri:uri url)
              (error () nil))))
      (unless uri
        (editor-error "Not a URL: ~a" url))
      (let ((scheme (quri:uri-scheme uri)))
        (unless (and scheme
                     (member scheme '("http" "https" "file")
                             :test #'string-equal))
          (editor-error "Unsupported Org download URL scheme: ~a"
                        (or scheme "none"))))
      (when (member (quri:uri-scheme uri) '("http" "https")
                    :test #'string-equal)
        (unless (and (quri:uri-host uri)
                     (plusp (length (quri:uri-host uri))))
          (editor-error "The Org download URL has no host")))
      (values url uri))))

(defun org-download-url-decode-path (path)
  ;; QURI treats `+' as form-encoded space.  A URI path uses a literal plus,
  ;; so protect it before applying the otherwise-correct UTF-8 percent decoder.
  (quri:url-decode
   (with-output-to-string (output)
     (loop :for character :across (or path "")
           :do (if (char= character #\+)
                   (write-string "%2B" output)
                   (write-char character output))))))

(defun org-download-file-url-pathname (uri)
  (let ((host (quri:uri-host uri)))
    (when (and host
               (plusp (length host))
               (not (string-equal host "localhost")))
      (editor-error "Remote file URLs are not supported")))
  (let* ((decoded
           (handler-case
               (org-download-url-decode-path (quri:uri-path uri))
             (error ()
               (editor-error "The file URL contains invalid escaping"))))
         (pathname (uiop:parse-native-namestring decoded)))
    (unless (uiop:absolute-pathname-p pathname)
      (editor-error "The file URL is not absolute"))
    pathname))

(defun org-download-open-temporary (root)
  "Return a new owner-only temporary pathname and descriptor below ROOT."
  #+sbcl
  (loop :repeat 32
        :for pathname :=
          (merge-pathnames
           (format nil ".lem-yath-download.~d.~16,'0x"
                   (sb-posix:getpid) (random (ash 1 60)))
           root)
        :do
           (handler-case
               (let ((descriptor
                       (sb-posix:open
                        (uiop:native-namestring pathname)
                        (logior sb-posix:o-creat sb-posix:o-excl
                                sb-posix:o-wronly sb-posix:o-nofollow)
                        #o600)))
                 (sb-posix:fchmod descriptor #o600)
                 (return (values pathname descriptor)))
             (sb-posix:syscall-error (condition)
               (unless (= (sb-posix:syscall-errno condition) sb-posix:eexist)
                 (error condition))))
        :finally (editor-error "Could not reserve an Org download temporary file"))
  #-sbcl
  (declare (ignore root))
  #-sbcl
  (editor-error "Secure Org downloads require the supported SBCL runtime"))

(defun org-download-copy-bounded-stream (input output process)
  "Copy binary INPUT to OUTPUT, enforcing the configured byte bound."
  (let ((chunk (make-array 65536 :element-type '(unsigned-byte 8)))
        (count 0))
    (loop :for length := (read-sequence chunk input)
          :until (zerop length)
          :do (incf count length)
              (when (> count *org-download-byte-limit*)
                (when process
                  (ignore-errors (uiop:terminate-process process)))
                (editor-error "Org download exceeds the ~a limit"
                              (org-download-byte-limit-label)))
              (write-sequence chunk output :end length))
    (when (zerop count)
      (editor-error "Org download produced no data"))
    count))

(defun org-download-call-with-temporary-output (root writer)
  "Call WRITER with a binary stream and return its complete temporary file."
  #+sbcl
  (multiple-value-bind (pathname descriptor)
      (org-download-open-temporary root)
    (let ((stream nil)
          (complete-p nil))
      (unwind-protect
           (progn
             (setf stream
                   (sb-sys:make-fd-stream
                    descriptor :output t :element-type '(unsigned-byte 8)
                    :buffering :full :name (uiop:native-namestring pathname))
                   descriptor nil)
             (funcall writer stream)
             (finish-output stream)
             (sb-posix:fsync (sb-sys:fd-stream-fd stream))
             (sb-posix:fchmod (sb-sys:fd-stream-fd stream) #o644)
             (close stream)
             (setf stream nil complete-p t)
             pathname)
        (when stream
          (ignore-errors (close stream :abort t)))
        (when descriptor
          (ignore-errors (sb-posix:close descriptor)))
        (unless complete-p
          (ignore-errors (delete-file pathname))))))
  #-sbcl
  (declare (ignore root writer))
  #-sbcl
  (editor-error "Secure Org downloads require the supported SBCL runtime"))

(defun org-download-run-program-to-temporary (root arguments &key input)
  "Run direct argv ARGUMENTS into a bounded binary file below ROOT."
  (org-download-call-with-temporary-output
   root
   (lambda (output)
     (let ((process nil)
           (finished-p nil)
           (input-stream (and input (make-string-input-stream input)))
           (*project-process-timeout* *org-download-process-timeout*))
       (unwind-protect
            (progn
              (setf process
                    (uiop:launch-program
                     (project-timeout-command arguments)
                     :input input-stream :output :stream :error-output nil
                     :element-type '(unsigned-byte 8)))
              (with-open-stream (stdout (uiop:process-info-output process))
                (org-download-copy-bounded-stream stdout output process))
              (let ((status (uiop:wait-process process)))
                (setf finished-p t)
                (unless (and (integerp status) (zerop status))
                  (editor-error "Org download command failed (exit ~a)" status))))
         (when (and process (not finished-p))
           (ignore-errors (uiop:terminate-process process))
           (ignore-errors (uiop:wait-process process)))
         (when input-stream
           (ignore-errors (close input-stream))))))))

(defun org-download-copy-local-to-temporary (root source)
  (let* ((pathname
           (or (ignore-errors (truename source))
               (editor-error "Org download file does not exist: ~a" source)))
         (stat (sb-posix:stat (uiop:native-namestring pathname))))
    (unless (= (logand (sb-posix:stat-mode stat) sb-posix:s-ifmt)
               sb-posix:s-ifreg)
      (editor-error "Org download source is not a regular file: ~a" pathname))
    (when (> (sb-posix:stat-size stat) *org-download-byte-limit*)
      (editor-error "Org download exceeds the ~a limit"
                    (org-download-byte-limit-label)))
    (org-download-call-with-temporary-output
     root
     (lambda (output)
       (with-open-file (input pathname :element-type '(unsigned-byte 8))
         (org-download-copy-bounded-stream input output nil))))))

(defun org-download-curl-config-quote (text)
  (with-output-to-string (output)
    (loop :for character :across text
          :do (when (member character '(#\\ #\"))
                (write-char #\\ output))
              (write-char character output))))

(defun org-download-http-to-temporary (root url)
  (let ((curl (or (executable-find "curl")
                  (editor-error "curl is unavailable; cannot download the image"))))
    (org-download-run-program-to-temporary
     root
     (list (uiop:native-namestring curl)
           "--config" "-"
           "--silent" "--fail" "--location"
           "--connect-timeout" "10"
           "--max-time" (princ-to-string *org-download-process-timeout*)
           "--max-filesize" (princ-to-string *org-download-byte-limit*)
           "--proto" "=http,https" "--proto-redir" "=http,https")
     :input (format nil "url = \"~a\"~%"
                    (org-download-curl-config-quote url)))))

(defun org-download-clipboard-arguments ()
  "Return the configured Linux clipboard image reader as direct argv."
  (if (string-equal (or (uiop:getenv "XDG_SESSION_TYPE") "") "wayland")
      (let ((program (or (executable-find "wl-paste")
                         (editor-error
                          "wl-paste is unavailable; install wl-clipboard"))))
        (list (uiop:native-namestring program) "--type" "image/png"))
      (let ((program (or (executable-find "xclip")
                         (editor-error "xclip is unavailable"))))
        (list (uiop:native-namestring program)
              "-selection" "clipboard" "-target" "image/png" "-out"))))

(defun org-download-octet-prefix-p (octets prefix &optional (offset 0))
  (and (<= (+ offset (length prefix)) (length octets))
       (loop :for expected :across prefix
             :for index :from offset
             :always (= expected (aref octets index)))))

(defun org-download-read-prefix (pathname &optional (limit 8192))
  (with-open-file (stream pathname :element-type '(unsigned-byte 8))
    (let* ((size (min limit (file-length stream)))
           (octets (make-array size :element-type '(unsigned-byte 8)))
           (count (read-sequence octets stream)))
      (if (= count size) octets (subseq octets 0 count)))))

(defun org-download-svg-prefix-p (octets)
  (handler-case
      (let* ((text (babel:octets-to-string octets :encoding :utf-8 :errorp t))
             (start (position-if-not
                     (lambda (character)
                       (or (member character '(#\Space #\Tab #\Newline #\Return))
                           (= (char-code character) #xfeff)))
                     text)))
        (and start
             (or (alexandria:starts-with-subseq "<svg" text :start2 start)
                 (let ((svg (search "<svg" text :start2 start)))
                   (and svg
                        (alexandria:starts-with-subseq "<?xml" text
                                                     :start2 start))))))
    (error () nil)))

(defun org-download-image-type (pathname)
  "Return a signature-proved image/PDF type for PATHNAME, or NIL."
  (let ((octets (org-download-read-prefix pathname)))
    (cond
      ((org-download-octet-prefix-p octets #(137 80 78 71 13 10 26 10)) :png)
      ((org-download-octet-prefix-p octets #(255 216 255)) :jpeg)
      ((or (org-download-octet-prefix-p octets #(71 73 70 56 55 97))
           (org-download-octet-prefix-p octets #(71 73 70 56 57 97))) :gif)
      ((and (org-download-octet-prefix-p octets #(82 73 70 70))
            (org-download-octet-prefix-p octets #(87 69 66 80) 8)) :webp)
      ((org-download-octet-prefix-p octets #(66 77)) :bmp)
      ((or (org-download-octet-prefix-p octets #(73 73 42 0))
           (org-download-octet-prefix-p octets #(77 77 0 42))) :tiff)
      ((org-download-octet-prefix-p octets #(0 0 1 0)) :ico)
      ((org-download-octet-prefix-p octets #(37 80 68 70 45)) :pdf)
      ((and (org-download-octet-prefix-p octets #(102 116 121 112) 4)
            (or (org-download-octet-prefix-p octets #(97 118 105 102) 8)
                (org-download-octet-prefix-p octets #(97 118 105 115) 8))) :avif)
      ((org-download-svg-prefix-p octets) :svg))))

(defun org-download-type-extension (type)
  (ecase type
    (:png "png") (:jpeg "jpg") (:gif "gif") (:webp "webp")
    (:bmp "bmp") (:tiff "tiff") (:ico "ico") (:pdf "pdf")
    (:avif "avif") (:svg "svg")))

(defun org-download-url-basename (uri)
  (let* ((path (or (quri:uri-path uri) ""))
         (slash (position #\/ path :from-end t))
         (encoded (subseq path (if slash (1+ slash) 0))))
    (handler-case
        (org-download-url-decode-path encoded)
      (error () "image"))))

(defun org-download-safe-basename (name)
  (let ((safe
          (with-output-to-string (output)
            (loop :for character :across name
                  :for code := (char-code character)
                  :do (write-char
                       (if (or (char= character #\/)
                               (char= character #\\)
                               (< code 32) (= code 127))
                           #\_
                           character)
                       output)))))
    (setf safe (string-trim '(#\Space #\Tab #\.) safe))
    (when (> (length safe) 120)
      (setf safe (subseq safe 0 120)))
    (if (or (zerop (length safe))
            (member safe '("." "..") :test #'string=))
        "image"
        safe)))

(defun org-download-basename-with-type (name type)
  (let* ((safe (org-download-safe-basename name))
         (dot (position #\. safe :from-end t))
         (stem (if (and dot (plusp dot)) (subseq safe 0 dot) safe)))
    (format nil "~a.~a" (org-download-safe-basename stem)
            (org-download-type-extension type))))

(defun org-download-timestamp-prefix (time)
  (multiple-value-bind (second minute hour day month year)
      (decode-universal-time time)
    (format nil "~4,'0d-~2,'0d-~2,'0d_~2,'0d-~2,'0d-~2,'0d_"
            year month day hour minute second)))

(defun org-download-annotation-time (time)
  (multiple-value-bind (second minute hour day month year)
      (decode-universal-time time)
    (format nil "~4,'0d-~2,'0d-~2,'0d ~2,'0d:~2,'0d:~2,'0d"
            year month day hour minute second)))

(defun org-download-org-link-escape (text)
  "Reproduce Org's backslash escaping for brackets and trailing slashes."
  (with-output-to-string (output)
    (loop :with index := 0
          :while (< index (length text))
          :do
             (let ((start index))
               (loop :while (and (< index (length text))
                                  (char= (char text index) #\\))
                     :do (incf index))
               (let ((slashes (- index start))
                     (sensitive-p
                       (or (= index (length text))
                           (and (< index (length text))
                                (member (char text index) '(#\[ #\]))))))
                 (loop :repeat (if sensitive-p (* 2 slashes) slashes)
                       :do (write-char #\\ output))
                 (when (< index (length text))
                   (when (member (char text index) '(#\[ #\]))
                     (write-char #\\ output))
                   (write-char (char text index) output)
                   (incf index)))))))

(defun org-download-relative-pathname (target base)
  "Return a lexical pathname from directory BASE to TARGET when possible."
  (let* ((absolute-target (uiop:ensure-absolute-pathname target))
         (absolute-base
           (uiop:ensure-directory-pathname
            (uiop:ensure-absolute-pathname base)))
         (target-directory (pathname-directory absolute-target))
         (base-directory (pathname-directory absolute-base)))
    (unless (and (equal (pathname-host absolute-target)
                        (pathname-host absolute-base))
                 (equal (pathname-device absolute-target)
                        (pathname-device absolute-base))
                 (eq (first target-directory) :absolute)
                 (eq (first base-directory) :absolute))
      (return-from org-download-relative-pathname absolute-target))
    (let ((target-parts (rest target-directory))
          (base-parts (rest base-directory)))
      (loop :while (and target-parts base-parts
                        (equal (first target-parts) (first base-parts)))
            :do (pop target-parts) (pop base-parts))
      (make-pathname
       :directory
       (cons :relative
             (append (make-list (length base-parts) :initial-element :up)
                     target-parts))
       :name (pathname-name absolute-target)
       :type (pathname-type absolute-target)
       :version (pathname-version absolute-target)))))

(defun org-download-relative-link (target buffer)
  (let* ((filename (buffer-filename buffer))
         (base
           (if filename
               (uiop:pathname-directory-pathname filename)
               (buffer-directory buffer)))
         (relative (org-download-relative-pathname target base))
         (native (uiop:native-namestring relative)))
    (org-download-org-link-escape (substitute #\/ #\\ native))))

(defun org-download-insert-link (point source target time)
  "Insert the configured annotation and relative file link at POINT."
  (with-point ((line point))
    (line-start line)
    (let ((prefix (points-to-string line point)))
      (if (and (plusp (length prefix))
               (every (lambda (character)
                        (member character '(#\Space #\Tab)))
                      prefix))
          (delete-between-points line point)
          (insert-character point #\Newline))))
  (insert-string
   point
   (format nil "#+DOWNLOADED: ~a @ ~a~%[[file:~a]]~%"
           source (org-download-annotation-time time)
           (org-download-relative-link target (point-buffer point)))))

(defun org-download-preflight-clipboard-heading ()
  (let ((heading (or (org-heading-point)
                     (editor-error "No Org heading at point"))))
    (with-point ((next heading))
      (when (line-offset next 1)
        (line-start next)
        (when (and (string= (line-string next) ":PROPERTIES:")
                   (null (org-property-drawer-end next)))
          (editor-error "Malformed Org property drawer: missing :END:"))))
    heading))

(defun org-download-commit (temporary target source time &optional heading)
  "Commit TEMPORARY and its Org link as one best-effort cross-resource edit."
  #+sbcl
  (let* ((buffer (current-buffer))
         (point (current-point))
         (group (buffer-prepare-change-group buffer))
         (linked-p nil)
         (accepted-p nil))
    (unwind-protect
         (progn
           (when heading
             (org-id-get-create-at-heading heading))
           (org-download-insert-link point source target time)
           (handler-case
               (sb-posix:link (uiop:native-namestring temporary)
                              (uiop:native-namestring target))
             (sb-posix:syscall-error (condition)
               (if (= (sb-posix:syscall-errno condition) sb-posix:eexist)
                   (editor-error "Org download target already exists: ~a" target)
                   (error condition))))
           (setf linked-p t)
           (delete-file temporary)
           (buffer-accept-change-group group)
           (setf accepted-p t)
           ;; M-x may restore its prompt buffer before the outer command hook
           ;; inserts a boundary, so seal the edited Org buffer explicitly.
           (buffer-undo-boundary buffer)
           target)
      (unless accepted-p
        (when (buffer-change-group-active-p group)
          (ignore-errors (buffer-cancel-change-group group)))
        (when linked-p
          (ignore-errors (delete-file target)))
        (ignore-errors (delete-file temporary)))))
  #-sbcl
  (declare (ignore temporary target source time heading))
  #-sbcl
  (editor-error "Secure Org downloads require the supported SBCL runtime"))

(defun org-download-url-temporary (root url uri)
  (if (string-equal (quri:uri-scheme uri) "file")
      (org-download-copy-local-to-temporary
       root (org-download-file-url-pathname uri))
      (org-download-http-to-temporary root url)))

(defun org-download-perform-url (text)
  (org-download-require-org-buffer)
  (multiple-value-bind (url uri) (org-download-parse-url text)
    (let* ((time (funcall *org-download-now-function*))
           (root (org-publish-ensure-output-root
                  (org-download-media-directory)))
           (temporary (org-download-url-temporary root url uri)))
      (unwind-protect
           (let ((type (org-download-image-type temporary)))
             (unless type
               (editor-error
                "The URL did not produce a recognized image or PDF"))
             (let* ((basename
                      (org-download-basename-with-type
                       (org-download-url-basename uri) type))
                    (target
                      (merge-pathnames
                       (concatenate
                        'string (org-download-timestamp-prefix time) basename)
                       root)))
               (org-download-commit temporary target url time)
               (setf temporary nil)
               (message "Downloaded Org image to ~a" target)))
        (when temporary
          (ignore-errors (delete-file temporary)))))))

(defun org-download-perform-clipboard (&optional basename)
  (org-download-require-org-buffer)
  (let* ((heading (org-download-preflight-clipboard-heading))
         (time (funcall *org-download-now-function*))
         (root (org-publish-ensure-output-root
                (org-download-media-directory)))
         (temporary
           (org-download-run-program-to-temporary
            root (org-download-clipboard-arguments))))
    (unwind-protect
         (progn
           (unless (eq (org-download-image-type temporary) :png)
             (editor-error "The clipboard did not contain a PNG image"))
           (let* ((name (or basename "screenshot.png"))
                  (target
                    (merge-pathnames
                     (concatenate
                      'string
                      (org-download-timestamp-prefix time)
                      (org-download-basename-with-type name :png))
                     root)))
             (org-download-commit temporary target "screenshot" time heading)
             (setf temporary nil)
             (message "Captured Org clipboard image to ~a" target)))
      (when temporary
        (ignore-errors (delete-file temporary))))))

(define-command org-download-yank () ()
  "Download the URL at the head of the kill ring into $WORKDIR/media/."
  (let ((text (lem/common/killring:peek-killring-item
               (current-killring) 0)))
    (org-download-perform-url text)))

(define-command org-download-clipboard () ()
  "Capture a PNG from the Linux clipboard into $WORKDIR/media/."
  (org-download-perform-clipboard))
