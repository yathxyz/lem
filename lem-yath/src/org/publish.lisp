;;;; Configured Org HTML export and project publishing.

(in-package :lem-yath)

(defparameter *org-publish-output-directory*
  (uiop:ensure-directory-pathname
   (merge-pathnames "proj/web/org-publishing/" (user-homedir-pathname)))
  "Configured destination for the Org-roam publishing projects.")

(defparameter *org-publish-file-count-limit* 20000)
(defparameter *org-publish-source-byte-limit* (* 16 1024 1024))
(defparameter *org-publish-total-source-byte-limit* (* 64 1024 1024))
(defparameter *org-publish-static-byte-limit* (* 64 1024 1024))
(defparameter *org-publish-scanner-output-limit* (* 16 1024 1024))
(defparameter *org-publish-html-output-limit* (* 32 1024 1024))
(defparameter *org-publish-process-timeout* 120)
(defparameter *org-publish-progress-interval* 50)

(defvar *org-publish-generation* 0)
(defvar *active-org-publish-request* nil)
(defvar *org-publish-buffer* nil)

(defstruct org-publish-source
  pathname
  relative
  output-relative
  text
  modified-at)

(defstruct org-publish-id-target
  output-relative
  anchor)

(defstruct org-publish-plan
  project
  output-root
  sources
  static-files
  id-index
  heading-index
  force-p)

(defstruct org-publish-counts
  (html-written 0)
  (html-skipped 0)
  (static-written 0)
  (static-skipped 0)
  (unresolved-links 0)
  (ambiguous-links 0))

(defun org-publish-notes-directory ()
  (uiop:ensure-directory-pathname (merge-pathnames "roam/" (workdir))))

(defun org-publish-static-directory ()
  (uiop:ensure-directory-pathname (workdir)))

(defun org-publish-stat-signature (stat)
  (list (sb-posix:stat-dev stat)
        (sb-posix:stat-ino stat)
        (sb-posix:stat-size stat)
        (sb-posix:stat-mtime stat)
        (let ((symbol (find-symbol "STAT-CTIME" :sb-posix)))
          (and symbol (fboundp symbol) (funcall symbol stat)))
        (let ((symbol (find-symbol "STAT-MTIME-NSEC" :sb-posix)))
          (and symbol (fboundp symbol) (funcall symbol stat)))
        (let ((symbol (find-symbol "STAT-CTIME-NSEC" :sb-posix)))
          (and symbol (fboundp symbol) (funcall symbol stat)))))

(defun org-publish-lstat (pathname)
  (handler-case
      (sb-posix:lstat (uiop:native-namestring pathname))
    (sb-posix:syscall-error () nil)))

(defun org-publish-regular-file-p (pathname)
  (alexandria:when-let ((stat (org-publish-lstat pathname)))
    (= (logand (sb-posix:stat-mode stat) sb-posix:s-ifmt)
       sb-posix:s-ifreg)))

(defun org-publish-directory-p (pathname)
  (alexandria:when-let ((stat (org-publish-lstat pathname)))
    (= (logand (sb-posix:stat-mode stat) sb-posix:s-ifmt)
       sb-posix:s-ifdir)))

(defun org-publish-opened-path-valid-p (descriptor pathname root)
  (let ((opened
          (ignore-errors
            (truename (format nil "/proc/self/fd/~d" descriptor)))))
    (and opened
         (project-path-in-directory-p opened root)
         (uiop:pathname-equal opened (truename pathname)))))

(defun org-publish-read-octets (pathname root limit)
  "Read a stable regular PATHNAME below ROOT without following a symlink."
  (let ((descriptor nil)
        (stream nil))
    (unwind-protect
         (progn
           (setf descriptor
                 (sb-posix:open
                  (uiop:native-namestring pathname)
                  (logior sb-posix:o-rdonly sb-posix:o-nonblock
                          sb-posix:o-nofollow)))
           (let* ((before (sb-posix:fstat descriptor))
                  (size (sb-posix:stat-size before)))
             (unless (= (logand (sb-posix:stat-mode before) sb-posix:s-ifmt)
                        sb-posix:s-ifreg)
               (error "Publishing source is not a regular file: ~a" pathname))
             (unless (org-publish-opened-path-valid-p descriptor pathname root)
               (error "Publishing source escaped its configured root: ~a" pathname))
             (when (> size limit)
               (error "Publishing source exceeds the ~:d-byte limit: ~a"
                      limit pathname))
             (let ((fd descriptor))
               (setf stream
                     (sb-sys:make-fd-stream
                      fd :input t :element-type '(unsigned-byte 8)
                      :buffering :full
                      :name (uiop:native-namestring pathname))
                     descriptor nil)
               (let ((octets (make-array size :element-type '(unsigned-byte 8)))
                     (count 0))
                 (loop :while (< count size)
                       :for next := (read-sequence octets stream :start count)
                       :do (when (= next count) (return))
                           (setf count next))
                 (let ((after (sb-posix:fstat fd)))
                   (unless (and (= count size)
                                (equal (org-publish-stat-signature before)
                                       (org-publish-stat-signature after)))
                     (error "Publishing source changed while being read: ~a"
                            pathname)))
                 octets))))
      (when stream
        (ignore-errors (close stream)))
      (when descriptor
        (ignore-errors (sb-posix:close descriptor))))))

(defun org-publish-read-text (pathname root)
  (let ((octets
          (org-publish-read-octets
           pathname root *org-publish-source-byte-limit*)))
    (when (find 0 octets)
      (error "Org publishing source contains a NUL byte: ~a" pathname))
    (handler-case
        (values (sb-ext:octets-to-string octets :external-format :utf-8)
                (length octets))
      (error ()
        (error "Org publishing source is not valid UTF-8: ~a" pathname)))))

(defun org-publish-find-command (root kind)
  (let ((find (or (executable-find "find")
                  (error "find is unavailable; cannot scan publishing roots"))))
    (ecase kind
      (:org
       (list (uiop:native-namestring find)
             (uiop:native-namestring root)
             "-type" "f" "-name" "*.org" "-print0"))
      (:static
       (list (uiop:native-namestring find)
             (uiop:native-namestring root)
             "-type" "f" "("
             "-name" "*.css" "-o" "-name" "*.txt"
             "-o" "-name" "*.jpg" "-o" "-name" "*.gif"
             "-o" "-name" "*.png" ")" "-print0")))))

(defun org-publish-split-nul-output (output)
  (let ((start 0)
        (paths nil))
    (loop :for end := (position #\Null output :start start)
          :while end
          :for value := (subseq output start end)
          :do (when (plusp (length value)) (push value paths))
              (setf start (1+ end)))
    (unless (= start (length output))
      (error "Publishing scanner returned unterminated output"))
    (when (> (length paths) *org-publish-file-count-limit*)
      (error "Publishing scan exceeds the ~:d-file limit"
             *org-publish-file-count-limit*))
    (nreverse paths)))

(defun org-publish-scan (root kind)
  "Return canonical regular files below ROOT without following symlinks."
  (let ((canonical-root (ignore-errors (truename root))))
    (unless canonical-root
      (return-from org-publish-scan nil))
    (let ((*project-process-timeout* *org-publish-process-timeout*))
      (multiple-value-bind (stdout stderr status)
          (run-project-program
           (org-publish-find-command canonical-root kind)
           :directory canonical-root
           :output-limit *org-publish-scanner-output-limit*)
        (unless (and (integerp status) (zerop status))
          (error "Publishing scan failed (~a): ~a" status
                 (string-trim '(#\Space #\Tab #\Newline #\Return) stderr)))
        (let ((seen (make-hash-table :test #'equal))
              (result nil))
          (dolist (name (org-publish-split-nul-output stdout)
                        (sort result #'string-lessp
                              :key #'uiop:native-namestring))
            (let ((pathname (ignore-errors (truename name))))
              (when (and pathname
                         (project-path-in-directory-p pathname canonical-root)
                         (org-publish-regular-file-p pathname))
                (let ((native (uiop:native-namestring pathname)))
                  (unless (gethash native seen)
                    (setf (gethash native seen) t)
                    (push pathname result)))))))))))

(defun org-publish-html-relative-path (relative)
  (make-pathname :type "html" :defaults relative))

(defun org-publish-load-sources ()
  (let* ((root (org-publish-notes-directory))
         (canonical-root (ignore-errors (truename root)))
         (total 0)
         (sources nil))
    (unless canonical-root
      (return-from org-publish-load-sources nil))
    (dolist (pathname (org-publish-scan canonical-root :org)
                      (nreverse sources))
      (multiple-value-bind (text bytes)
          (org-publish-read-text pathname canonical-root)
        (incf total bytes)
        (when (> total *org-publish-total-source-byte-limit*)
          (error "Org publishing corpus exceeds the ~:d-byte limit"
                 *org-publish-total-source-byte-limit*))
        (let ((relative (pathname (enough-namestring pathname canonical-root))))
          (push (make-org-publish-source
                 :pathname pathname
                 :relative relative
                 :output-relative (org-publish-html-relative-path relative)
                 :text text
                 :modified-at (or (file-write-date pathname) 0))
                sources))))))

(defun org-publish-index-put (table key value)
  (multiple-value-bind (old present-p) (gethash key table)
    (setf (gethash key table)
          (if present-p
              (if (equalp old value) old :ambiguous)
              value))))

(defun org-publish-build-indexes (sources)
  "Return unique ID and (file,title) indexes for SOURCES."
  (let ((ids (make-hash-table :test #'equal))
        (headings (make-hash-table :test #'equal)))
    (dolist (source sources)
      (let ((nodes
              (roam-org-nodes
               (org-publish-source-pathname source)
               (uiop:native-namestring (org-publish-source-relative source))
               (roam-text-lines (org-publish-source-text source))
               (org-publish-source-modified-at source))))
        (dolist (node nodes)
          (let* ((id (roam-node-id node))
                 (kind (roam-node-kind node))
                 (target
                   (make-org-publish-id-target
                    :output-relative
                    (org-publish-html-relative-path
                     (pathname (roam-node-relative-path node)))
                    :anchor (and (eq kind :org-heading) id))))
            (org-publish-index-put ids (string-downcase id) target)
            (when (eq kind :org-heading)
              (org-publish-index-put
               headings
               (list (string-downcase (roam-node-relative-path node))
                     (string-downcase (roam-node-title node)))
               target))))))
    (values ids headings)))

(defun org-publish-url-path (pathname)
  (substitute #\/ #\\ (uiop:native-namestring pathname)))

(defun org-publish-relative-url (from-output-relative target)
  (let* ((from-directory
           (uiop:pathname-directory-pathname from-output-relative))
         (relative
           (pathname (enough-namestring
                      (org-publish-id-target-output-relative target)
                      from-directory)))
         (url (org-publish-url-path relative))
         (anchor (org-publish-id-target-anchor target)))
    (if anchor (format nil "~a#~a" url anchor) url)))

(defun org-publish-rewrite-id-links (text source id-index)
  "Rewrite bracketed id: links in TEXT for SOURCE.

Return rewritten text, unresolved count, and ambiguous count."
  (let ((cursor 0)
        (unresolved 0)
        (ambiguous 0))
    (values
     (with-output-to-string (output)
       (loop :for start := (search "[[id:" text :start2 cursor
                                    :test #'char-equal)
             :while start
             :for target-start := (+ start 2)
             :for id-start := (+ start 5)
             :for end := (position #\] text :start id-start)
             :do
                (unless end
                  (write-string text output :start cursor)
                  (return))
                (write-string text output :start cursor :end target-start)
                (let* ((id (subseq text id-start end))
                       (target (gethash (string-downcase id) id-index)))
                  (cond
                    ((eq target :ambiguous)
                     (incf ambiguous)
                     (write-string id output))
                    (target
                     (write-string
                      (org-publish-relative-url
                       (org-publish-source-output-relative source) target)
                      output))
                    (t
                     (incf unresolved)
                     (write-string (concatenate 'string "id:" id) output))))
                (setf cursor end)
             :finally (write-string text output :start cursor)))
     unresolved ambiguous)))

(defun org-publish-pandoc-heading-id (title)
  "Return Pandoc's ordinary auto-identifier approximation for TITLE."
  (let ((pending-hyphen nil)
        (wrote-p nil))
    (string-downcase
     (string-left-trim
      '(#\- #\_ #\.)
      (with-output-to-string (output)
        (loop :for character :across title
              :do
                 (cond
                   ((or (alphanumericp character)
                        (member character '(#\_ #\- #\.)))
                    (when (and pending-hyphen wrote-p)
                      (write-char #\- output))
                    (setf pending-hyphen nil)
                    (write-char character output)
                    (setf wrote-p t))
                   ((member character '(#\Space #\Tab #\Newline))
                    (setf pending-hyphen t)))))))))

(defun org-publish-resolve-source-relative (source path)
  (let* ((base (uiop:pathname-directory-pathname
                (org-publish-source-pathname source)))
         (target (ignore-errors (truename (merge-pathnames path base))))
         (root (ignore-errors (truename (org-publish-notes-directory)))))
    (and target root
         (project-path-in-directory-p target root)
         (uiop:native-namestring (pathname (enough-namestring target root))))))

(defun org-publish-rewrite-file-link-target
    (target source heading-index)
  (unless (alexandria:starts-with-subseq "file:" target
                                         :test #'char-equal)
    (return-from org-publish-rewrite-file-link-target nil))
  (let* ((body (subseq target 5))
         (separator (search "::" body))
         (path (if separator (subseq body 0 separator) body))
         (search-part (and separator (subseq body (+ separator 2)))))
    (unless (and (>= (length path) 4)
                 (string-equal ".org" path :start2 (- (length path) 4)))
      (return-from org-publish-rewrite-file-link-target nil))
    (let* ((html-path (concatenate 'string (subseq path 0 (- (length path) 4))
                                   ".html"))
           (anchor
             (cond
               ((null search-part) nil)
               ((alexandria:starts-with-subseq "#" search-part)
                (subseq search-part 1))
               ((alexandria:starts-with-subseq "*" search-part)
                (let* ((title (string-trim '(#\Space #\*) search-part))
                       (target-source
                         (org-publish-resolve-source-relative source path))
                       (indexed
                         (and target-source
                              (gethash
                               (list (string-downcase target-source)
                                     (string-downcase title))
                               heading-index))))
                  (if (and indexed (not (eq indexed :ambiguous)))
                      (org-publish-id-target-anchor indexed)
                      (org-publish-pandoc-heading-id title)))))))
      (format nil "file:~a~@[#~a~]" html-path anchor))))

(defun org-publish-rewrite-file-links (text source heading-index)
  (let ((cursor 0))
    (with-output-to-string (output)
      (loop :for start := (search "[[file:" text :start2 cursor
                                   :test #'char-equal)
            :while start
            :for target-start := (+ start 2)
            :for end := (position #\] text :start target-start)
            :do
               (unless end
                 (write-string text output :start cursor)
                 (return))
               (write-string text output :start cursor :end target-start)
               (let* ((target (subseq text target-start end))
                      (replacement
                        (org-publish-rewrite-file-link-target
                         target source heading-index)))
                 (write-string (or replacement target) output))
               (setf cursor end)
            :finally (write-string text output :start cursor)))))

(defun org-publish-source-title (source)
  (or (cl-ppcre:register-groups-bind (title)
          ("(?im)^#\+title:\s*(.*?)\s*$" (org-publish-source-text source))
        (and (plusp (length title)) title))
      (pathname-name (org-publish-source-pathname source))))

(defun org-publish-render-source (source id-index heading-index request)
  (multiple-value-bind (id-rewritten unresolved ambiguous)
      (org-publish-rewrite-id-links
       (org-publish-source-text source) source id-index)
    (let* ((input
             (org-publish-rewrite-file-links
              id-rewritten source heading-index))
           (pandoc (or (executable-find "pandoc")
                       (error "pandoc is unavailable; cannot export Org HTML")))
           (arguments
             (list (uiop:native-namestring pandoc)
                   "--from=org" "--to=html5" "--standalone"
                   "--wrap=none" "--mathjax"
                   "--metadata"
                   (format nil "pagetitle=~a" (org-publish-source-title source)))))
      (let ((*project-process-timeout* *org-publish-process-timeout*))
        (multiple-value-bind (stdout stderr status)
            (run-project-program
             arguments
             :directory (uiop:pathname-directory-pathname
                         (org-publish-source-pathname source))
             :request request
             :input input
             :output-limit *org-publish-html-output-limit*)
          (unless (or (null request) (project-request-live-p request))
            (error 'project-request-cancelled))
          (unless (and (integerp status) (zerop status))
            (error "Pandoc failed for ~a (~a): ~a"
                   (org-publish-source-relative source) status
                   (let ((diagnostic
                           (string-trim '(#\Space #\Tab #\Newline #\Return)
                                        stderr)))
                     (if (> (length diagnostic) 1000)
                         (subseq diagnostic 0 1000)
                         diagnostic))))
          (values stdout unresolved ambiguous))))))

(defun org-publish-relative-components (relative)
  (let ((directory (pathname-directory relative)))
    (when (null directory)
      (return-from org-publish-relative-components nil))
    (unless (and (consp directory) (eq (first directory) :relative))
      (error "Publishing target is not relative: ~a" relative))
    (dolist (component (rest directory))
      (unless (and (stringp component)
                   (plusp (length component))
                   (not (member component '("." "..") :test #'string=)))
        (error "Publishing target contains an unsafe directory: ~a" relative)))
    (rest directory)))

(defun org-publish-ensure-output-root (root)
  (let ((placeholder (merge-pathnames ".lem-yath-publish-root" root)))
    (ensure-directories-exist placeholder)
    (or (ignore-errors (truename root))
        (error "Could not create publishing output directory: ~a" root))))

(defun org-publish-ensure-target-parent (root relative)
  "Create RELATIVE's directory components under canonical ROOT.

Existing symbolic-link or non-directory components are rejected."
  (let ((current (uiop:ensure-directory-pathname root)))
    (dolist (component (org-publish-relative-components relative) current)
      (let ((next
              (merge-pathnames
               (uiop:ensure-directory-pathname component) current)))
        (alexandria:if-let ((stat (org-publish-lstat next)))
          (unless (= (logand (sb-posix:stat-mode stat) sb-posix:s-ifmt)
                     sb-posix:s-ifdir)
            (error "Publishing output component is not a directory: ~a" next))
          (sb-posix:mkdir (uiop:native-namestring next) #o755))
        (setf current (truename next))
        (unless (project-path-in-directory-p current root)
          (error "Publishing output directory escaped its root: ~a" next))))))

(defun org-publish-temporary-pathname (target)
  (uiop:parse-native-namestring
   (format nil "~a.tmp.~d.~16,'0x"
           (uiop:native-namestring target)
           (sb-posix:getpid)
           (random (ash 1 60)))))

(defun org-publish-check-existing-target (target)
  (alexandria:when-let ((stat (org-publish-lstat target)))
    (unless (and (= (logand (sb-posix:stat-mode stat) sb-posix:s-ifmt)
                    sb-posix:s-ifreg)
                 (= (sb-posix:stat-uid stat) (sb-posix:getuid)))
      (error "Refusing to replace a non-regular or unowned output: ~a" target))))

(defun org-publish-write-octets-atomically (root relative octets)
  (let* ((canonical-root (org-publish-ensure-output-root root))
         (parent (org-publish-ensure-target-parent canonical-root relative))
         (target (merge-pathnames (file-namestring relative) parent))
         (temporary (org-publish-temporary-pathname target))
         (descriptor nil)
         (stream nil))
    (org-publish-check-existing-target target)
    (unwind-protect
         (progn
           (setf descriptor
                 (sb-posix:open
                  (uiop:native-namestring temporary)
                  (logior sb-posix:o-creat sb-posix:o-excl
                          sb-posix:o-wronly sb-posix:o-nofollow)
                  #o644))
           (sb-posix:fchmod descriptor #o644)
           (setf stream
                 (sb-sys:make-fd-stream
                  descriptor :output t :element-type '(unsigned-byte 8)
                  :buffering :full :name (uiop:native-namestring temporary)))
           (write-sequence octets stream)
           (finish-output stream)
           (sb-posix:fsync descriptor)
           (close stream)
           (setf stream nil
                 descriptor nil)
           (uiop:rename-file-overwriting-target temporary target)
           target)
      (when stream
        (ignore-errors (close stream :abort t)))
      (when descriptor
        (ignore-errors (sb-posix:close descriptor)))
      (when (org-publish-lstat temporary)
        (ignore-errors (delete-file temporary))))))

(defun org-publish-write-text-atomically (root relative text)
  (org-publish-write-octets-atomically
   root relative
   (sb-ext:string-to-octets text :external-format :utf-8)))

(defun org-publish-output-pathname (root relative)
  (merge-pathnames relative root))

(defun org-publish-output-fresh-p (output source-time)
  (and (org-publish-regular-file-p output)
       (>= (or (file-write-date output) 0) source-time)))

(defun org-publish-log-buffer ()
  (or (and *org-publish-buffer*
           (not (deleted-buffer-p *org-publish-buffer*))
           *org-publish-buffer*)
      (setf *org-publish-buffer* (make-buffer "*Org Publish*"))))

(defun org-publish-log (control &rest arguments)
  (append-line (org-publish-log-buffer)
               (apply #'format nil control arguments)))

(defun org-publish-check-request (request)
  (unless (project-request-live-p request)
    (error 'project-request-cancelled)))

(defun org-publish-one-source (source plan request counts)
  (org-publish-check-request request)
  (let* ((root (org-publish-plan-output-root plan))
         (relative (org-publish-source-output-relative source))
         (output (org-publish-output-pathname root relative)))
    (if (and (not (org-publish-plan-force-p plan))
             (org-publish-output-fresh-p
              output (org-publish-source-modified-at source)))
        (incf (org-publish-counts-html-skipped counts))
        (multiple-value-bind (html unresolved ambiguous)
            (org-publish-render-source
             source
             (org-publish-plan-id-index plan)
             (org-publish-plan-heading-index plan)
             request)
          (org-publish-write-text-atomically root relative html)
          (incf (org-publish-counts-html-written counts))
          (incf (org-publish-counts-unresolved-links counts) unresolved)
          (incf (org-publish-counts-ambiguous-links counts) ambiguous)))))

(defun org-publish-static-relative (pathname root)
  (pathname (enough-namestring pathname root)))

(defun org-publish-one-static (pathname plan request counts)
  (org-publish-check-request request)
  (let* ((source-root (truename (org-publish-static-directory)))
         (relative (org-publish-static-relative pathname source-root))
         (output-root (org-publish-plan-output-root plan))
         (output (org-publish-output-pathname output-root relative))
         (source-time (or (file-write-date pathname) 0)))
    (if (and (not (org-publish-plan-force-p plan))
             (org-publish-output-fresh-p output source-time))
        (incf (org-publish-counts-static-skipped counts))
        (progn
          (org-publish-write-octets-atomically
           output-root relative
           (org-publish-read-octets
            pathname source-root *org-publish-static-byte-limit*))
          (incf (org-publish-counts-static-written counts))))))

(defun org-publish-run-plan (plan request)
  (let ((counts (make-org-publish-counts))
        (processed 0)
        (total (+ (length (org-publish-plan-sources plan))
                  (length (org-publish-plan-static-files plan)))))
    (dolist (source (org-publish-plan-sources plan))
      (org-publish-one-source source plan request counts)
      (incf processed)
      (when (or (= processed total)
                (zerop (mod processed *org-publish-progress-interval*)))
        (org-publish-log "Progress: ~:d/~:d files" processed total)))
    (dolist (pathname (org-publish-plan-static-files plan))
      (org-publish-one-static pathname plan request counts)
      (incf processed)
      (when (or (= processed total)
                (zerop (mod processed *org-publish-progress-interval*)))
        (org-publish-log "Progress: ~:d/~:d files" processed total)))
    counts))

(defun org-publish-project-components (project)
  (cond
    ((string= project "org-roam-notes") (values t nil))
    ((string= project "static") (values nil t))
    ((string= project "org-roam") (values t t))
    (t (editor-error "Unknown Org publishing project: ~a" project))))

(defun org-publish-make-plan (project force-p &optional only-source)
  (multiple-value-bind (notes-p static-p)
      (org-publish-project-components project)
    (let* ((all-sources (and notes-p (org-publish-load-sources)))
           (sources
             (if only-source
                 (remove-if-not
                  (lambda (source)
                    (uiop:pathname-equal
                     (org-publish-source-pathname source) only-source))
                  all-sources)
                 all-sources))
           (static-files
             (and static-p
                  (org-publish-scan (org-publish-static-directory) :static))))
      (when (and only-source (null sources))
        (editor-error "Current file is not in the org-roam-notes project"))
      (multiple-value-bind (ids headings)
          (if all-sources
              (org-publish-build-indexes all-sources)
              (values (make-hash-table :test #'equal)
                      (make-hash-table :test #'equal)))
        (make-org-publish-plan
         :project project
         :output-root *org-publish-output-directory*
         :sources sources
         :static-files static-files
         :id-index ids
         :heading-index headings
         :force-p force-p)))))

(defun org-publish-finish-request (request control &rest arguments)
  (send-event
   (lambda ()
     (when (eq request *active-org-publish-request*)
       (setf *active-org-publish-request* nil)
       (apply #'message control arguments)))))

(defun org-publish-start-plan (plan)
  (when *active-org-publish-request*
    (cancel-project-request *active-org-publish-request*))
  (let* ((request
           (make-live-project-request
            (incf *org-publish-generation*)
            (capture-project-request-origin)))
         (buffer (org-publish-log-buffer)))
    (setf *active-org-publish-request* request)
    (erase-buffer buffer)
    (setf (buffer-directory buffer) (org-publish-plan-output-root plan)
          (buffer-value buffer 'lem-yath-direnv-process-buffer) t)
    (pop-to-buffer buffer)
    (insert-string
     (buffer-end-point buffer)
     (format nil "Publishing ~a~:[ incrementally~; forcibly~] to ~a~%"
             (org-publish-plan-project plan)
             (org-publish-plan-force-p plan)
             (org-publish-plan-output-root plan)))
    (bt2:make-thread
     (lambda ()
       (handler-case
           (let ((counts (org-publish-run-plan plan request)))
             (org-publish-log
              "Done: HTML ~:d written/~:d unchanged; static ~:d written/~:d unchanged; links ~:d unresolved/~:d ambiguous."
              (org-publish-counts-html-written counts)
              (org-publish-counts-html-skipped counts)
              (org-publish-counts-static-written counts)
              (org-publish-counts-static-skipped counts)
              (org-publish-counts-unresolved-links counts)
              (org-publish-counts-ambiguous-links counts))
             (org-publish-finish-request
              request "Published Org project ~a"
              (org-publish-plan-project plan)))
         (project-request-cancelled ()
           (org-publish-log "Cancelled.")
           (org-publish-finish-request request "Org publishing cancelled"))
         (error (condition)
           (org-publish-log "Failed: ~a" condition)
           (org-publish-finish-request request "Org publishing failed: ~a"
                                       condition))))
     :name "lem-yath/org-publish")
    request))

(defun org-publish-project (project &key force only-source)
  "Prepare and asynchronously publish configured PROJECT."
  (org-publish-start-plan
   (org-publish-make-plan project force only-source)))

(define-command lem-yath-org-publish () ()
  "Incrementally publish the configured composite Org-roam project."
  (org-publish-project "org-roam"))

(define-command lem-yath-org-publish-force () ()
  "Republish every file in the configured composite Org-roam project."
  (org-publish-project "org-roam" :force t))

(defun org-publish-current-file ()
  (let ((pathname (or (buffer-filename (current-buffer))
                      (editor-error "Current Org buffer has no file"))))
    (org-publish-project "org-roam-notes" :force t :only-source pathname)))

(define-command lem-yath-org-publish-current-file () ()
  "Publish the current saved Org file into the configured project output."
  (org-publish-current-file))

(define-command lem-yath-org-publish-all-projects () ()
  "Publish all configured projects; equivalent to the composite project."
  (org-publish-project "org-roam"))

(defun org-publish-choose-project ()
  (let ((project
          (string-trim
           '(#\Space #\Tab)
           (prompt-for-string
            "Publish project (org-roam/org-roam-notes/static): "
            :initial-value "org-roam"))))
    (org-publish-project project)))

(define-command lem-yath-org-publish-choose-project () ()
  "Prompt for one of the three configured Org publishing projects."
  (org-publish-choose-project))

(define-command lem-yath-org-publish-cancel () ()
  "Cancel the active Org publishing subprocess and remaining work."
  (alexandria:if-let ((request *active-org-publish-request*))
    (progn
      (cancel-project-request request)
      (message "Cancelling Org publishing"))
    (message "No Org publishing job is active")))

(defun org-export-current-source ()
  (let* ((buffer (current-buffer))
         (pathname (or (buffer-filename buffer)
                       (editor-error "Current Org buffer has no file")))
         (text (points-to-string (buffer-start-point buffer)
                                 (buffer-end-point buffer)))
         (notes-root (org-publish-notes-directory))
         (relative
           (if (project-path-in-directory-p pathname notes-root)
               (pathname (enough-namestring pathname (truename notes-root)))
               (make-pathname :name (pathname-name pathname)
                              :type (pathname-type pathname)))))
    (when (sops-buffer-active-p buffer)
      (editor-error "Org export will not write plaintext from a SOPS buffer"))
    (when (> (length (sb-ext:string-to-octets text :external-format :utf-8))
             *org-publish-source-byte-limit*)
      (editor-error "Org buffer exceeds the ~:d-byte export limit"
                    *org-publish-source-byte-limit*))
    (make-org-publish-source
     :pathname pathname
     :relative relative
     :output-relative (org-publish-html-relative-path relative)
     :text text
     :modified-at (get-universal-time))))

(defun org-export-current-to-html ()
  (let* ((source (org-export-current-source))
         (all-sources
           (if (project-path-in-directory-p
                (org-publish-source-pathname source)
                (org-publish-notes-directory))
               (org-publish-load-sources)
               nil)))
    (multiple-value-bind (ids headings)
        (if all-sources
            (org-publish-build-indexes all-sources)
            (values (make-hash-table :test #'equal)
                    (make-hash-table :test #'equal)))
      (multiple-value-bind (html unresolved ambiguous)
          (org-publish-render-source source ids headings nil)
        (let* ((directory
                 (uiop:pathname-directory-pathname
                  (org-publish-source-pathname source)))
               (relative (org-publish-source-output-relative source))
               (output
                 (org-publish-write-text-atomically
                  directory
                  (make-pathname
                   :name (pathname-name relative) :type "html")
                  html)))
          (message "Exported HTML to ~a (~:d unresolved, ~:d ambiguous links)"
                   output unresolved ambiguous)
          output)))))

(define-command lem-yath-org-export-html () ()
  "Export the live Org buffer to a sibling standalone HTML file."
  (org-export-current-to-html))

(define-command lem-yath-org-export-html-and-open () ()
  "Export the live Org buffer to HTML and open it externally."
  (open-with-xdg
   (uiop:native-namestring (org-export-current-to-html))))

(defun org-export-dispatch-read-key (prompt)
  (message "~a" prompt)
  (redraw-display)
  (with-last-read-key-sequence
    (let ((key (read-key)))
      (when (abort-key-p key)
        (error 'editor-abort))
      (lem-core::keyseq-to-string (list key)))))

(define-command lem-yath-org-export-dispatch () ()
  "Read and execute the useful suffixes of GNU Org's export dispatcher."
  (let ((branch
          (org-export-dispatch-read-key
           "Export: h HTML; P publish (C-g cancels)")))
    (cond
      ((string-equal branch "h")
       (let ((action
               (org-export-dispatch-read-key
                "HTML: h file; o file and open")))
         (cond
           ((string-equal action "h")
            (org-export-current-to-html))
           ((string-equal action "o")
            (open-with-xdg
             (uiop:native-namestring (org-export-current-to-html))))
           (t (message "No HTML export action is bound to ~a" action)))))
      ((string-equal branch "P")
       (let ((action
               (org-export-dispatch-read-key
                "Publish: f file; p project; a all; x choose")))
         (cond
           ((string-equal action "f")
            (org-publish-current-file))
           ((string-equal action "p")
            (org-publish-project "org-roam"))
           ((string-equal action "a")
            (org-publish-project "org-roam"))
           ((string-equal action "x")
            (org-publish-choose-project))
           (t (message "No publishing action is bound to ~a" action)))))
      (t (message "No Org export branch is bound to ~a" branch)))))

(define-key *org-mode-keymap* "C-c C-e" 'lem-yath-org-export-dispatch)
