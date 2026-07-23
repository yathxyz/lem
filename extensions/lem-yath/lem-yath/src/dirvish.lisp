;;;; Pinned Dirvish presentation shared by directory and find-name buffers.

(in-package :lem-yath)

(define-attribute dirvish-size-attribute
  (t :foreground :base03))

(define-attribute dirvish-modeline-symlink-attribute
  (t :foreground :base0D))

(defconstant +dirvish-file-count-overflow+ 15000)

(defun dirvish-native-path (path)
  (etypecase path
    (string path)
    (pathname (uiop:native-namestring path))))

(defun dirvish-live-window-p (window)
  (and window (not (lem-core::window-deleted-p window))))

(defun dirvish-live-buffer-p (buffer)
  (and buffer (not (deleted-buffer-p buffer))))

(defun dirvish-directory-blank-header-line-p (point)
  "Hide directory-mode's redundant blank row below its path header."
  (= (line-number-at-point point) 2))

(defun dirvish-window-selected-path (window)
  (when (and window
             (dirvish-live-window-p window)
             (eq (buffer-major-mode (window-buffer window))
                 'lem/directory-mode/mode:directory-mode))
    (lem/directory-mode/internal:get-pathname
     (window-point window))))

(defun dirvish-modeline-sort (window)
  (declare (ignore window))
  " ↑ name|mtime ")

(defun dirvish-modeline-symlink (window)
  (let ((pathname (dirvish-window-selected-path window)))
    (if (and pathname
             (ignore-errors
               (= (logand (sb-posix:stat-mode
                            (sb-posix:lstat (dirvish-native-path pathname)))
                           sb-posix:s-ifmt)
                  sb-posix:s-iflnk)))
        (alexandria:when-let ((target (ignore-errors (probe-file pathname))))
          (values (format nil "→ ~a "
                          (completion-path-display-string
                           (dirvish-native-path target)))
                  'dirvish-modeline-symlink-attribute))
        "")))

(defun dirvish-modeline-index (window)
  (let* ((buffer (window-buffer window))
         (pathname (dirvish-window-selected-path window))
         (current (if pathname
                      (max 0 (- (line-number-at-point
                                 (window-point window))
                                2))
                      0))
         (total (max 0 (- (buffer-nlines buffer) 3))))
    (values (format nil "~3d /~3d " current total) nil :right)))

(defparameter +dirvish-ordinary-modeline-format+
  '(dirvish-modeline-sort
    dirvish-modeline-symlink
    (dirvish-modeline-index nil :right)))

(defun ensure-dirvish-directory-presentation (buffer)
  "Apply pinned Dirvish chrome to an ordinary directory BUFFER."
  (when (eq (buffer-major-mode buffer)
            'lem/directory-mode/mode:directory-mode)
    (setf (variable-value 'modeline-format :buffer buffer)
          +dirvish-ordinary-modeline-format+
          (variable-value 'lem-core::line-hidden-function :buffer buffer)
          'dirvish-directory-blank-header-line-p)))

(remove-hook *switch-to-buffer-hook* 'ensure-dirvish-directory-presentation)
(add-hook *switch-to-buffer-hook* 'ensure-dirvish-directory-presentation)

(dolist (buffer (buffer-list))
  (ensure-dirvish-directory-presentation buffer))

(defun dirvish-count-directory-entries (path)
  "Count PATH's direct children, bounded like pinned Dirvish."
  (let ((program (executable-find "find")))
    (unless program
      (error "Required find executable is unavailable"))
    (multiple-value-bind (output error-output exit-code)
        (uiop:run-program
         (list (namestring program)
               "-H" (dirvish-native-path path)
               "-mindepth" "1" "-maxdepth" "1" "-printf" ".")
         :output :string
         :error-output :string
         :ignore-error-status t)
      (unless (and (integerp exit-code) (zerop exit-code))
        (error "find failed~@[ (~a)~]: ~a"
               exit-code
               (let ((detail
                       (string-trim '(#\Space #\Tab #\Newline #\Return)
                                    error-output)))
                 (if (plusp (length detail)) detail "no diagnostic"))))
      (let ((count (length output)))
        (if (>= count (- +dirvish-file-count-overflow+ 2))
            :many
            count)))))

(defun dirvish-six-cell-field (text)
  (let ((length (length text)))
    (cond
      ((> length 6) (subseq text (- length 6)))
      ((< length 6)
       (concatenate 'string
                    (make-string (- 6 length) :initial-element #\Space)
                    text))
      (t text))))

(defun dirvish-human-readable (number base)
  "Format NUMBER in pinned Dirvish's six-cell size/count representation."
  (let ((value (coerce number 'double-float))
        (base (coerce base 'double-float))
        (prefixes '("" "k" "M" "G" "T" "P" "E" "Z" "Y")))
    (loop :while (and (>= value base) (rest prefixes))
          :do (setf value (/ value base)
                    prefixes (rest prefixes)))
    (let* ((fraction (mod value 1d0))
           (fractional-p
             (and (< value 10d0)
                  (>= fraction 0.05d0)
                  (< fraction 0.95d0))))
      (dirvish-six-cell-field
       (format nil
               (if fractional-p "~,1f~a" "~d~a")
               (if fractional-p value (round value))
               (first prefixes))))))

(defun dirvish-size-field (path)
  "Return pinned Dirvish's six-cell default size attribute for PATH."
  (handler-case
      (let* ((native (dirvish-native-path path))
             (stat (sb-posix:lstat native))
             (type (logand (sb-posix:stat-mode stat) sb-posix:s-ifmt)))
        (cond
          ((= type sb-posix:s-ifdir)
           (let ((count (dirvish-count-directory-entries native)))
             (if (eq count :many)
                 " MANY "
                 (dirvish-human-readable count 1000))))
          ((= type sb-posix:s-iflnk)
           (handler-case
               (let ((target (sb-posix:stat native)))
                 (if (= (logand (sb-posix:stat-mode target) sb-posix:s-ifmt)
                        sb-posix:s-ifdir)
                     (let ((count (dirvish-count-directory-entries native)))
                       (if (eq count :many)
                           " MANY "
                           (dirvish-human-readable count 1000)))
                     (dirvish-human-readable
                      (sb-posix:stat-size target) 1024)))
             (error ()
               (dirvish-human-readable (sb-posix:stat-size stat) 1024))))
          (t
           (dirvish-human-readable (sb-posix:stat-size stat) 1024))))
    (error () " ---- ")))

(defun insert-dirvish-directory-entry (point item)
  "Insert ITEM as a hidden-details Dirvish row and retain display metadata."
  (let* ((pathname (lem/directory-mode/internal:item-pathname item))
         (name (lem/directory-mode/internal::item-name item))
         (start (copy-point point :temporary)))
    (line-start start)
    (insert-string
     point name
     :attribute (lem/directory-mode/internal::get-file-attribute pathname)
     :file pathname)
    (when (lem/directory-mode/file:symbolic-link-p pathname)
      (insert-string point (format nil " -> ~A" (probe-file pathname))))
    (put-text-property start point :dirvish-size
                       (dirvish-size-field pathname))))

;; Dirvish hides Dired's details by default.  The configured attribute list is
;; only (file-size), rendered later without adding bytes to the buffer.
(setf lem/directory-mode/internal:*file-entry-inserters*
      (list #'insert-dirvish-directory-entry))

(defun dirvish-extend-display-size (logical-line width size)
  "Right-align six-cell SIZE in LOGICAL-LINE without changing source text."
  (let* ((string (lem-core::logical-line-string logical-line))
         (display-width (lem/common/character:string-width string))
         (padding (- width display-width (length size))))
    (when (plusp padding)
      (let* ((source-end (length string))
             (start (+ source-end padding))
             (end (+ start (length size)))
             (cursor
               (lem-core::logical-line-end-of-line-cursor-attribute
                logical-line))
             (attributes (lem-core::logical-line-attributes logical-line)))
        (setf string
              (concatenate 'string string
                           (make-string padding :initial-element #\Space)
                           size))
        (when cursor
          (setf attributes
                (lem-core::overlay-attributes
                 attributes source-end (1+ source-end) cursor)
                (lem-core::logical-line-end-of-line-cursor-attribute
                 logical-line)
                nil))
        (setf (lem-core::logical-line-string logical-line) string
              (lem-core::logical-line-attributes logical-line)
              (lem-core::overlay-attributes
               attributes start end 'dirvish-size-attribute))))))

(defun dirvish-presentation-buffer-p (buffer)
  (member (buffer-major-mode buffer)
          '(lem/directory-mode/mode:directory-mode lem-yath-find-name-mode)))

(defun transform-dirvish-display-line (buffer point logical-line window)
  "Add the configured Dirvish size attribute to a visible file row."
  (when (and window
             (dirvish-presentation-buffer-p buffer)
             (>= (lem-core::window-body-width window) 20))
    (alexandria:when-let ((size (text-property-at point :dirvish-size)))
      (dirvish-extend-display-size
       logical-line (lem-core::window-body-width window) size))))

;;; --- Full-frame Dirvish session ------------------------------------------

(defconstant +dirvish-preview-directory-limit+ 200)
(defconstant +dirvish-preview-debounce-milliseconds+ 20)
(defconstant +dirvish-preview-throttle-milliseconds+ 250)
(defconstant +dirvish-preview-process-timeout+ 3)
(defconstant +dirvish-preview-process-output-limit+ (* 512 1024))
(defconstant +dirvish-preview-derived-input-limit+ (* 128 1024 1024))

(defclass dirvish-session ()
  ((frame :initarg :frame :reader dirvish-session-frame)
   (saved-layout :initarg :saved-layout :accessor dirvish-session-saved-layout)
   (root-window :initarg :root-window :reader dirvish-session-root-window)
   (parent-window :initarg :parent-window :reader dirvish-session-parent-window)
   (preview-window :initarg :preview-window :reader dirvish-session-preview-window)
   (preview-buffer :initarg :preview-buffer :reader dirvish-session-preview-buffer)
   (root-directory :initform nil :accessor dirvish-session-root-directory)
   (preview-path :initform nil :accessor dirvish-session-preview-path)
   (preview-timer :initform nil :accessor dirvish-session-preview-timer)
   (preview-request :initform nil :accessor dirvish-session-preview-request)
   (preview-generation :initform 0 :accessor dirvish-session-preview-generation)
   (last-preview-time :initform nil :accessor dirvish-session-last-preview-time)))

(defvar *dirvish-sessions* (make-hash-table :test #'eq))

(defun current-dirvish-session ()
  (gethash (current-frame) *dirvish-sessions*))

(defun dirvish-session-window-p (session window)
  (member window
          (list (dirvish-session-root-window session)
                (dirvish-session-parent-window session)
                (dirvish-session-preview-window session))
          :test #'eq))

(defun dirvish-root-buffer (session)
  (let ((window (dirvish-session-root-window session)))
    (and (dirvish-live-window-p window) (window-buffer window))))

(defun dirvish-root-directory (session)
  (alexandria:when-let ((buffer (dirvish-root-buffer session)))
    (and (eq (buffer-major-mode buffer)
             'lem/directory-mode/mode:directory-mode)
         (buffer-directory buffer))))

(defun dirvish-root-selected-path (session)
  (let ((window (dirvish-session-root-window session)))
    (when (and (dirvish-live-window-p window)
               (eq (buffer-major-mode (window-buffer window))
                   'lem/directory-mode/mode:directory-mode))
      (with-current-window window
        (lem/directory-mode/internal:get-pathname (current-point))))))

(defun dirvish-switch-window-buffer (window buffer)
  (when (and (dirvish-live-window-p window)
             (dirvish-live-buffer-p buffer))
    (ensure-dirvish-directory-presentation buffer)
    (with-current-window window
      (lem-core::%switch-to-buffer buffer nil t)
      (setf (window-parameter window 'lem-core::horizontal-scroll-start) 0))))

(defun dirvish-position-on-path (window pathname)
  (when (dirvish-live-window-p window)
    (with-current-window window
      (with-point ((point (buffer-start-point (current-buffer))))
        (loop
          (alexandria:when-let
              ((row-path (lem/directory-mode/internal:get-pathname point)))
            (when (ignore-errors (uiop:pathname-equal row-path pathname))
              (move-point (current-point) point)
              (window-recenter window)
              (return t)))
          (unless (line-offset point 1)
            (return nil)))))))

(defun dirvish-update-parent (session directory)
  (let* ((parent (uiop:pathname-parent-directory-pathname directory))
         (buffer (lem/directory-mode/internal:directory-buffer parent))
         (window (dirvish-session-parent-window session)))
    (dirvish-switch-window-buffer window buffer)
    (dirvish-position-on-path window directory)))

(defun dirvish-preview-safe-name (name)
  (map 'string
       (lambda (character)
         (if (or (char< character #\Space) (char= character #\Rubout))
             #\?
             character))
       name))

(defun dirvish-preview-display-path (pathname)
  "Return PATHNAME escaped onto one terminal row without changing identity."
  (completion-path-display-string (dirvish-native-path pathname)))

(defun dirvish-preview-directory-text (pathname)
  "Return a bounded, nonrecursive directory preview for PATHNAME."
  (let ((directory nil)
        (names nil)
        (truncated-p nil))
    (unwind-protect
         (progn
           (setf directory (sb-posix:opendir (dirvish-native-path pathname)))
           (loop :for entry := (sb-posix:readdir directory)
                 ;; SB-POSIX returns a non-NIL null alien at end-of-directory.
                 :until (sb-alien:null-alien entry)
                 ;; READDIR may reuse its foreign entry storage on the next
                 ;; call.  Retain only an immediate Lisp-owned copy.
                 :for name := (copy-seq (sb-posix:dirent-name entry))
                 :unless (or (string= name ".") (string= name ".."))
                   :do (if (< (length names)
                              +dirvish-preview-directory-limit+)
                           (push name names)
                           (progn
                             (setf truncated-p t)
                             (return))))
           (setf names (sort names #'string-lessp))
           (with-output-to-string (stream)
             (format stream "~a~2%" (dirvish-preview-display-path pathname))
             (dolist (name names)
               (let* ((child (merge-pathnames name pathname))
                      (directory-p
                        (handler-case
                            (= (logand (sb-posix:stat-mode
                                        (sb-posix:lstat
                                         (dirvish-native-path child)))
                                       sb-posix:s-ifmt)
                               sb-posix:s-ifdir)
                          (error () nil))))
                 (format stream "~a~:[~;/~]~%"
                         (dirvish-preview-safe-name name)
                         directory-p)))
             (when truncated-p
               (format stream "~%... first ~d entries shown ...~%"
                       +dirvish-preview-directory-limit+))))
      (when directory
        (sb-posix:closedir directory)))))

(defun dirvish-preview-file-description (pathname stat &optional reason)
  (let ((type (logand (sb-posix:stat-mode stat) sb-posix:s-ifmt)))
    (format nil
            "~a~2%Type: ~a~%Size: ~d bytes~@[~2%~a~]~%"
            (dirvish-preview-display-path pathname)
            (cond
              ((= type sb-posix:s-iflnk) "symbolic link")
              ((= type sb-posix:s-ififo) "named pipe")
              ((= type sb-posix:s-ifsock) "socket")
              ((= type sb-posix:s-ifchr) "character device")
              ((= type sb-posix:s-ifblk) "block device")
              ((= type sb-posix:s-ifreg) "regular file")
              (t "special file"))
            (sb-posix:stat-size stat)
            reason)))

(defun dirvish-preview-derived-kind (pathname)
  "Return the bounded external preview kind implied by PATHNAME, or NIL."
  (let ((name (string-downcase (file-namestring pathname))))
    (flet ((suffix-p (suffixes)
             (some (lambda (suffix)
                     (alexandria:ends-with-subseq suffix name))
                   suffixes)))
      (cond
        ((suffix-p '(".pdf")) :pdf)
        ((suffix-p '(".epub")) :epub)
        ((suffix-p '(".tar.gz" ".tar.bz2" ".tar.xz" ".tgz" ".tbz2"
                     ".txz" ".zip" ".tar" ".7z" ".rar" ".cpio" ".iso"))
         :archive)
        ((suffix-p '(".png" ".jpg" ".jpeg" ".gif" ".webp" ".bmp"
                     ".tif" ".tiff" ".svg" ".avif" ".heic" ".mp3"
                     ".flac" ".ogg" ".wav" ".m4a" ".mp4" ".mkv"
                     ".webm" ".avi" ".mov" ".mpeg" ".mpg"))
         :media)))))

(defun dirvish-preview-run (program arguments directory request)
  "Run one preview PROGRAM as direct argv under strict time/output bounds."
  (let ((executable (or (executable-find program)
                        (error "~a is unavailable" program)))
        (*project-process-timeout* +dirvish-preview-process-timeout+))
    (multiple-value-bind (stdout stderr status)
        (run-project-program
         (cons (uiop:native-namestring executable) arguments)
         :directory directory
         :request request
         :output-limit +dirvish-preview-process-output-limit+)
      (unless (and (integerp status) (zerop status))
        (let ((diagnostic
                (completion-first-documentation-line
                 (document-safe-display-text stderr))))
          (error "~a failed~@[ (~a)~]" program diagnostic)))
      (document-safe-display-text stdout))))

(defun dirvish-preview-pdf-text (pathname request)
  (let* ((native (dirvish-native-path pathname))
         (directory (directory-namestring pathname))
         (info (dirvish-preview-run "pdfinfo" (list native)
                                    directory request))
         (pages (document-ascii-integer
                 (or (document-pdf-info-field info "Pages") "")))
         (title (document-pdf-info-field info "Title"))
         (author (document-pdf-info-field info "Author"))
         (page-text
           (dirvish-preview-run
            "pdftotext"
            (list "-f" "1" "-l" "1" "-layout" "-nopgbrk"
                  "-enc" "UTF-8" native "-")
            directory request)))
    (with-output-to-string (stream)
      (format stream "~a~2%PDF document~%"
              (dirvish-preview-display-path pathname))
      (when (and title (plusp (length title)))
        (format stream "Title: ~a~%" title))
      (when (and author (plusp (length author)))
        (format stream "Author: ~a~%" author))
      (format stream "Page 1~@[ of ~d~]~%~a~2%"
              pages (make-string 60 :initial-element #\-))
      (if (plusp (length (string-trim '(#\Space #\Tab #\Newline #\Return)
                                      page-text)))
          (write-string page-text stream)
          (write-string "[The first page has no extractable text.]" stream))
      (terpri stream))))

(defun dirvish-preview-epub-text (pathname request)
  (let* ((native (dirvish-native-path pathname))
         (content
           (dirvish-preview-run
            "pandoc"
            (list "--sandbox" "--from=epub" "--to=plain" "--wrap=none"
                  native)
            (directory-namestring pathname) request)))
    (format nil "~a~2%EPUB document~%~a~2%~a~%"
            (dirvish-preview-display-path pathname)
            (make-string 60 :initial-element #\-) content)))

(defun dirvish-preview-archive-text (pathname request)
  (let* ((native (dirvish-native-path pathname))
         (output
           (dirvish-preview-run
            "bsdtar" (list "-tf" native)
            (directory-namestring pathname) request))
         (members
           (remove-if
            (lambda (line) (zerop (length line)))
            (mapcar #'dirvish-preview-safe-name
                    (cl-ppcre:split "\\r?\\n" output))))
         (truncated-p (> (length members) +dirvish-preview-directory-limit+)))
    (with-output-to-string (stream)
      (format stream "~a~2%Archive members~%~a~2%"
              (dirvish-preview-display-path pathname)
              (make-string 60 :initial-element #\-))
      (dolist (member (subseq members 0 (min (length members)
                                             +dirvish-preview-directory-limit+)))
        (format stream "~a~%" member))
      (when truncated-p
        (format stream "~%... first ~d members shown ...~%"
                +dirvish-preview-directory-limit+)))))

(defun dirvish-preview-media-text (pathname request)
  (let* ((native (dirvish-native-path pathname))
         (description
           (string-trim
            '(#\Space #\Tab #\Newline #\Return)
            (dirvish-preview-run
             "file" (list "--brief" "--" native)
             (directory-namestring pathname) request))))
    (format nil "~a~2%Media metadata~%~a~%"
            (dirvish-preview-display-path pathname)
            (if (plusp (length description)) description "unknown"))))

(defun dirvish-preview-derived-text (kind pathname request)
  (ecase kind
    (:pdf (dirvish-preview-pdf-text pathname request))
    (:epub (dirvish-preview-epub-text pathname request))
    (:archive (dirvish-preview-archive-text pathname request))
    (:media (dirvish-preview-media-text pathname request))))

(defun dirvish-preview-text (pathname &key request)
  "Return a safe textual preview for PATHNAME without activating file modes."
  (handler-case
      (let* ((stat (sb-posix:lstat (dirvish-native-path pathname)))
             (type (logand (sb-posix:stat-mode stat) sb-posix:s-ifmt)))
        (cond
          ((= type sb-posix:s-ifdir)
           (dirvish-preview-directory-text pathname))
          ((= type sb-posix:s-ifreg)
           (let ((kind (dirvish-preview-derived-kind pathname)))
             (cond
               ((and kind
                     (not (eq kind :media))
                     (> (sb-posix:stat-size stat)
                        +dirvish-preview-derived-input-limit+))
                (dirvish-preview-file-description
                 pathname stat
                 "Derived preview skipped: file is larger than 128 MiB."))
               (kind
                (dirvish-preview-derived-text kind pathname request))
               (t
                (alexandria:if-let
                    ((text (project-picker-read-preview-text pathname)))
                  (format nil "~a~2%~a"
                          (dirvish-preview-display-path pathname)
                          text)
                  (dirvish-preview-file-description
                   pathname stat
                   "Preview unavailable: file is binary, undecodable, or larger than 1 MiB."))))))
          (t
           (dirvish-preview-file-description
            pathname stat "Special files are never opened for preview."))))
    (project-request-cancelled (condition)
      (error condition))
    (error (condition)
      (format nil "~a~2%Preview unavailable: ~a~%"
              (dirvish-preview-display-path pathname) condition))))

(defun dirvish-render-preview-buffer (session pathname &optional text)
  (let ((buffer (dirvish-session-preview-buffer session)))
    (when (dirvish-live-buffer-p buffer)
      (with-buffer-read-only buffer nil
        (erase-buffer buffer)
        (insert-string (buffer-start-point buffer)
                       (or text (dirvish-preview-text pathname))))
      (setf (buffer-directory buffer)
            (or (uiop:directory-exists-p pathname)
                (uiop:pathname-directory-pathname pathname))
            (buffer-read-only-p buffer) t)
      (buffer-unmark buffer)
      (buffer-start (buffer-point buffer))
      (alexandria:when-let ((window (dirvish-session-preview-window session)))
        (when (dirvish-live-window-p window)
          (move-point (lem-core::%window-point window)
                      (buffer-start-point buffer))
          (move-point (window-view-point window)
                      (buffer-start-point buffer))))
      (setf (dirvish-session-last-preview-time session)
            (get-internal-real-time))
      (redraw-display))))

(defun dirvish-cancel-preview-request (session)
  (alexandria:when-let ((request (dirvish-session-preview-request session)))
    (setf (dirvish-session-preview-request session) nil)
    (cancel-project-request request)))

(defun dirvish-start-derived-preview (session pathname generation)
  "Render PATHNAME off the editor thread and publish only the current result."
  (let* ((key (dirvish-native-path pathname))
         (display-path (dirvish-preview-display-path pathname))
         (request
           (%make-project-request generation (capture-project-request-origin))))
    (setf (dirvish-session-preview-request session) request)
    (dirvish-render-preview-buffer
     session pathname
     (format nil "~a~2%Loading bounded preview ...~%" display-path))
    (bt2:make-thread
     (lambda ()
       (handler-case
           (let ((text (dirvish-preview-text pathname :request request)))
             (send-event
              (lambda ()
                (when (and (= generation
                              (dirvish-session-preview-generation session))
                           (eq request
                               (dirvish-session-preview-request session))
                           (eq session
                               (gethash (dirvish-session-frame session)
                                        *dirvish-sessions*))
                           (string= key
                                    (or (dirvish-session-preview-path session)
                                        "")))
                  (setf (dirvish-session-preview-request session) nil)
                  (dirvish-render-preview-buffer session pathname text)))))
         (project-request-cancelled ())
         (error (condition)
           (send-event
            (lambda ()
              (when (and (= generation
                            (dirvish-session-preview-generation session))
                         (eq request
                             (dirvish-session-preview-request session)))
                (setf (dirvish-session-preview-request session) nil)
                (dirvish-render-preview-buffer
                 session pathname
                 (format nil "~a~2%Preview unavailable: ~a~%"
                         display-path condition))))))))
     :name "lem-yath/dirvish-preview")))

(defun dirvish-render-current-preview (session pathname)
  (let ((generation (dirvish-session-preview-generation session)))
    (if (dirvish-preview-derived-kind pathname)
        (dirvish-start-derived-preview session pathname generation)
        (dirvish-render-preview-buffer session pathname))))

(defun dirvish-stop-preview-timer (session)
  (incf (dirvish-session-preview-generation session))
  (dirvish-cancel-preview-request session)
  (alexandria:when-let ((timer (dirvish-session-preview-timer session)))
    (ignore-errors (stop-timer timer))
    (setf (dirvish-session-preview-timer session) nil)))

(defun dirvish-preview-delay (session)
  (let ((last (dirvish-session-last-preview-time session)))
    (if (null last)
        +dirvish-preview-debounce-milliseconds+
        (let ((elapsed
                (floor
                 (* 1000
                    (/ (- (get-internal-real-time) last)
                       internal-time-units-per-second)))))
          (max +dirvish-preview-debounce-milliseconds+
               (- +dirvish-preview-throttle-milliseconds+ elapsed))))))

(defun dirvish-schedule-preview (session pathname &optional immediate-p)
  (let ((key (dirvish-native-path pathname)))
    (unless (string= key (or (dirvish-session-preview-path session) ""))
      (dirvish-stop-preview-timer session)
      (setf (dirvish-session-preview-path session) key)
      (if immediate-p
          (dirvish-render-current-preview session pathname)
          (let* ((generation (dirvish-session-preview-generation session))
                 (timer
                   (make-timer
                    (lambda ()
                      (setf (dirvish-session-preview-timer session) nil)
                      (when (and (= generation
                                    (dirvish-session-preview-generation session))
                                 (eq session (gethash (dirvish-session-frame session)
                                                      *dirvish-sessions*)))
                        (alexandria:when-let
                            ((current (dirvish-root-selected-path session)))
                          (when (string= key (dirvish-native-path current))
                            (dirvish-render-current-preview session current)))))
                    :name "lem-yath Dirvish preview")))
            (setf (dirvish-session-preview-timer session) timer)
            (start-timer timer (dirvish-preview-delay session) :repeat nil))))))

(defun dirvish-refresh-session (session &optional immediate-preview-p)
  (alexandria:when-let ((directory (dirvish-root-directory session)))
    (unless (and (dirvish-session-root-directory session)
                 (ignore-errors
                   (uiop:pathname-equal
                    directory (dirvish-session-root-directory session))))
      (setf (dirvish-session-root-directory session) directory)
      (dirvish-update-parent session directory))
    (alexandria:when-let ((pathname (dirvish-root-selected-path session)))
      (dirvish-schedule-preview session pathname immediate-preview-p))))

(defun dirvish-delete-preview-buffer (session)
  (let ((buffer (dirvish-session-preview-buffer session)))
    (when (dirvish-live-buffer-p buffer)
      (ignore-errors
        (with-global-variable-value (kill-buffer-hook nil)
          (delete-buffer buffer))))))

(defun dirvish-setup-session-chrome (session)
  (setf (lem-core::window-modeline-format
         (dirvish-session-parent-window session))
        '("")
        (lem-core::window-modeline-format
         (dirvish-session-root-window session))
        '(dirvish-modeline-sort
          dirvish-modeline-symlink
          (dirvish-modeline-index nil :right))
        (lem-core::window-modeline-format
         (dirvish-session-preview-window session))
        '("")))

(defun dirvish-restore-session-layout (session root-buffer keep-root-p)
  (let* ((configuration (dirvish-session-saved-layout session))
         (restored-p
           (and configuration
                (handler-case
                    (restore-window-layout configuration)
                  (error () nil)))))
    (unless restored-p
      (alexandria:when-let ((root-window (dirvish-session-root-window session)))
        (when (dirvish-live-window-p root-window)
          (switch-to-window root-window)))
      (delete-other-windows)
      (when (dirvish-live-buffer-p root-buffer)
        (switch-to-buffer root-buffer)))
    (when (and keep-root-p (dirvish-live-buffer-p root-buffer))
      (switch-to-buffer root-buffer))
    (when configuration
      (dispose-window-layout configuration)
      (setf (dirvish-session-saved-layout session) nil))
    restored-p))

(defun quit-dirvish-session (session &key keep-root)
  (let ((root-buffer (dirvish-root-buffer session)))
    (dirvish-stop-preview-timer session)
    (remhash (dirvish-session-frame session) *dirvish-sessions*)
    (let ((restored-p
            (dirvish-restore-session-layout session root-buffer keep-root)))
      (dirvish-delete-preview-buffer session)
      (unless restored-p
        (message "The prior layout contained a dead buffer; kept Dirvish directory instead"))
      restored-p)))

(defun dirvish-make-preview-buffer (directory)
  (let ((buffer
          (make-buffer (unique-buffer-name "*Dirvish Preview*")
                       :temporary t
                       :enable-undo-p nil
                       :read-only-p t
                       :directory directory)))
    (setf (buffer-encoding buffer)
          (lem/buffer/encodings:encoding :utf-8 :lf))
    buffer))

(defun start-dirvish-session (directory)
  (let* ((directory
           (or (uiop:directory-exists-p directory)
               (editor-error "Directory does not exist: ~a" directory)))
         (root-buffer
           (lem/directory-mode/internal:directory-buffer directory))
         (configuration (capture-window-layout))
         (preview-buffer nil))
    (unless configuration
      (editor-error "The current window layout cannot be recorded"))
    (handler-case
        (progn
          (setf preview-buffer (dirvish-make-preview-buffer directory))
          (delete-other-windows)
          (switch-to-buffer root-buffer)
          (let* ((parent-window (current-window))
                 (total-width (window-width parent-window))
                 (parent-width (max 8 (round (* total-width 0.11d0)))))
            (split-window-horizontally parent-window :width parent-width)
            (let* ((root-window (get-next-window parent-window))
                   (root-width (max 12 (round (* total-width 0.34d0)))))
              (split-window-horizontally root-window :width root-width)
              (let* ((preview-window (get-next-window root-window))
                     (session
                       (make-instance
                        'dirvish-session
                        :frame (current-frame)
                        :saved-layout configuration
                        :root-window root-window
                        :parent-window parent-window
                        :preview-window preview-window
                        :preview-buffer preview-buffer)))
                (setf (gethash (current-frame) *dirvish-sessions*) session)
                (dirvish-switch-window-buffer preview-window preview-buffer)
                (switch-to-window root-window)
                (dirvish-setup-session-chrome session)
                (dirvish-refresh-session session t)
                session))))
      (error (condition)
        (ignore-errors (restore-window-layout configuration))
        (dispose-window-layout configuration)
        (when (dirvish-live-buffer-p preview-buffer)
          (ignore-errors (delete-buffer preview-buffer)))
        (error condition)))))

(defun dirvish-open-directory (directory)
  (alexandria:if-let ((session (current-dirvish-session)))
    (let ((buffer (lem/directory-mode/internal:directory-buffer directory)))
      (dirvish-switch-window-buffer (dirvish-session-root-window session) buffer)
      (switch-to-window (dirvish-session-root-window session))
      (setf (dirvish-session-root-directory session) nil
            (dirvish-session-preview-path session) nil)
      (dirvish-refresh-session session t)
      session)
    (start-dirvish-session directory)))

(define-command dirvish (argument) (:universal-nil)
  "Open a full-frame parent/current/preview Dirvish session.

With a prefix argument, prompt for the directory.  Otherwise use the current
buffer's directory, matching pinned Dirvish."
  (dirvish-open-directory
   (if argument
       (prompt-for-directory "Dirvish: " :directory (buffer-directory))
       (buffer-directory))))

(define-command dirvish-layout-toggle () ()
  "Toggle between full-frame Dirvish and the ordinary directory buffer."
  (alexandria:if-let ((session (current-dirvish-session)))
    (quit-dirvish-session session :keep-root t)
    (dirvish-open-directory (buffer-directory))))

(define-command lem-yath-dirvish-quit () ()
  (alexandria:if-let ((session (current-dirvish-session)))
    (if (dirvish-session-window-p session (current-window))
        (quit-dirvish-session session)
        (quit-active-window))
    (quit-active-window)))

(defun dirvish-open-selected (read-only-p)
  (alexandria:if-let ((session (current-dirvish-session)))
    (if (eq (current-window) (dirvish-session-root-window session))
        (alexandria:if-let
            ((pathname
               (lem/directory-mode/internal:get-pathname (current-point))))
          (if (uiop:directory-exists-p pathname)
              (if read-only-p
                  (lem/directory-mode/commands:directory-mode-read-file)
                  (lem/directory-mode/commands:directory-mode-find-file))
              (progn
                (quit-dirvish-session session)
                (if read-only-p (read-file pathname) (find-file pathname))))
          (editor-error "No file on this line"))
        (if read-only-p
            (lem/directory-mode/commands:directory-mode-read-file)
            (lem/directory-mode/commands:directory-mode-find-file)))
    (if read-only-p
        (lem/directory-mode/commands:directory-mode-read-file)
        (lem/directory-mode/commands:directory-mode-find-file))))

(define-command lem-yath-dirvish-find-file () ()
  (dirvish-open-selected nil))

(define-command lem-yath-dirvish-read-file () ()
  (dirvish-open-selected t))

(defun dirvish-post-command ()
  (alexandria:when-let ((session (current-dirvish-session)))
    (let ((root-buffer (dirvish-root-buffer session)))
      (cond
        ((not (dirvish-live-buffer-p root-buffer))
         (quit-dirvish-session session))
        ((eq (buffer-major-mode root-buffer)
             'lem/directory-mode/mode:directory-mode)
         (dirvish-refresh-session session))
        (t
         (quit-dirvish-session session)
         (when (dirvish-live-buffer-p root-buffer)
           (switch-to-buffer root-buffer)))))))

(define-key lem/directory-mode/mode:*directory-mode-keymap*
  "q" 'lem-yath-dirvish-quit)
(define-key lem/directory-mode/mode:*directory-mode-keymap*
  "M-q" 'lem-yath-dirvish-quit)
(define-key lem/directory-mode/mode:*directory-mode-keymap*
  "Return" 'lem-yath-dirvish-find-file)
(define-key lem/directory-mode/mode:*directory-mode-keymap*
  "Space" 'lem-yath-dirvish-read-file)

(remove-hook *post-command-hook* 'dirvish-post-command)
(add-hook *post-command-hook* 'dirvish-post-command -375)
