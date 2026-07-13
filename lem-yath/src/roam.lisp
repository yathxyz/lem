;;;; Metadata-aware org-roam/md-roam workflows over $WORKDIR/roam.
;;;; Candidate identity remains the captured node object; titles, aliases,
;;;; tags, and IDs are bounded display/search metadata, never action paths.

(in-package :lem-yath)

(defparameter *roam-file-byte-limit* (* 1024 1024)
  "Largest individual note accepted by the bounded node index.")

(defparameter *roam-total-byte-limit* (* 64 1024 1024)
  "Largest aggregate note corpus accepted by one picker snapshot.")

(defparameter *roam-file-count-limit* 20000)
(defparameter *roam-node-count-limit* 50000)
(defparameter *roam-metadata-value-limit* 4096)
(defparameter *roam-scanner-character-limit* (* 16 1024 1024))
(defparameter *roam-pathname-character-limit* 16384)

(defstruct (roam-node (:constructor %make-roam-node))
  id
  kind
  pathname
  relative-path
  line
  level
  title
  aliases
  tags
  modified-at)

(defun roam-directory ()
  (uiop:ensure-directory-pathname (merge-pathnames "roam/" (workdir))))

(defun roam-path-in-root-p (pathname root)
  (handler-case
      (alexandria:starts-with-subseq
       (uiop:native-namestring (truename root))
       (uiop:native-namestring (truename pathname)))
    (error () nil)))

(defun roam-file-command (root)
  (cond
    ((executable-find "fd")
     (list (uiop:native-namestring (executable-find "fd"))
           "--absolute-path" "--hidden" "--no-ignore" "--type" "f"
           "--extension" "org" "--extension" "md"
           "--print0" "." (uiop:native-namestring root)))
    ((executable-find "find")
     (list (uiop:native-namestring (executable-find "find"))
           (uiop:native-namestring root)
           "-type" "f" "(" "-name" "*.org" "-o" "-name" "*.md" ")"
           "-print0"))))

(defun roam-run-file-command (command)
  "Read NUL-delimited scanner output without allocating beyond index limits."
  (let ((process nil)
        (finished-p nil))
    (unwind-protect
         (progn
           (setf process
                 (uiop:launch-program command :output :stream
                                              :error-output nil))
           (let ((names '())
                 (name (make-string-output-stream))
                 (name-count 0)
                 (name-length 0)
                 (total-length 0)
                 (malformed-p nil))
             (labels ((finish-name ()
                        (let ((value (get-output-stream-string name)))
                          (setf name (make-string-output-stream)
                                name-length 0)
                          (when (plusp (length value))
                            (push value names)
                            (incf name-count)
                            (when (> name-count *roam-file-count-limit*)
                              (editor-error
                               "Roam index exceeds the ~d-file safety limit."
                               *roam-file-count-limit*))))))
               (with-open-stream (stream (uiop:process-info-output process))
                 (loop :for character := (read-char stream nil nil)
                       :while character
                       :do (if (char= character #\Null)
                               (finish-name)
                               (progn
                                 (incf name-length)
                                 (incf total-length)
                                 (when (> name-length
                                          *roam-pathname-character-limit*)
                                   (editor-error
                                    "Roam scanner returned an overlong pathname."))
                                 (when (> total-length
                                          *roam-scanner-character-limit*)
                                   (editor-error
                                    "Roam scanner output exceeds its safety limit."))
                                 (write-char character name))))
                 (when (plusp name-length)
                   (setf malformed-p t)))
               (let ((status (uiop:wait-process process)))
                 (setf finished-p t)
                 (and (zerop status)
                      (not malformed-p)
                      (nreverse names))))))
      (when (and process (not finished-p))
        (ignore-errors (uiop:terminate-process process))
        (ignore-errors (uiop:wait-process process))))))

(defun roam-listed-pathnames ()
  "Return canonical regular note files below the roam root without following
directory symlinks.  A failed or unavailable scanner produces no candidates."
  (let* ((root (roam-directory))
         (canonical-root (ignore-errors (truename root)))
         (command (and canonical-root (roam-file-command canonical-root)))
         (names (and command (roam-run-file-command command))))
    (let ((seen (make-hash-table :test #'equal))
          (pathnames '()))
      (dolist (name names (nreverse pathnames))
        (let ((pathname
                (and (plusp (length name))
                     (not (search ".sync-conflict-" name :test #'char-equal))
                     (ignore-errors (truename name)))))
          (when (and pathname
                     (roam-path-in-root-p pathname canonical-root))
            (let ((key (uiop:native-namestring pathname)))
              (unless (gethash key seen)
                (setf (gethash key seen) t)
                (push pathname pathnames)))))))))

(defun roam-stat-optional-value (stat accessor-name)
  (let ((accessor (find-symbol accessor-name :sb-posix)))
    (and accessor (fboundp accessor) (funcall accessor stat))))

(defun roam-stat-signature (stat)
  (list (sb-posix:stat-dev stat)
        (sb-posix:stat-ino stat)
        (sb-posix:stat-size stat)
        (sb-posix:stat-mtime stat)
        (roam-stat-optional-value stat "STAT-CTIME")
        (roam-stat-optional-value stat "STAT-MTIME-NSEC")
        (roam-stat-optional-value stat "STAT-CTIME-NSEC")))

(defun roam-read-open-flags ()
  (let ((no-follow (find-symbol "O-NOFOLLOW" :sb-posix)))
    (logior sb-posix:o-rdonly
            sb-posix:o-nonblock
            (if (and no-follow (boundp no-follow))
                (symbol-value no-follow)
                0))))

(defun roam-opened-path-valid-p (descriptor pathname root)
  (let ((opened
          (ignore-errors
            (truename (format nil "/proc/self/fd/~d" descriptor)))))
    (and opened
         root
         (roam-path-in-root-p opened root)
         (string= (uiop:native-namestring opened)
                  (uiop:native-namestring pathname)))))

(defun roam-read-note (pathname &optional
                                  (root (ignore-errors
                                          (truename (roam-directory)))))
  "Read one bounded, descriptor-verified regular UTF-8 file.
Returns text, byte count, and a status keyword."
  (let ((descriptor nil)
        (stream nil))
    (unwind-protect
         (handler-case
             (progn
               (setf descriptor
                     (sb-posix:open
                      (uiop:native-namestring pathname)
                      (roam-read-open-flags)))
               (let* ((before (sb-posix:fstat descriptor))
                      (size (sb-posix:stat-size before)))
                 (unless (roam-opened-path-valid-p descriptor pathname root)
                   (return-from roam-read-note (values nil 0 :outside)))
                 (unless (= (logand (sb-posix:stat-mode before) sb-posix:s-ifmt)
                            sb-posix:s-ifreg)
                   (return-from roam-read-note (values nil 0 :special)))
                 (when (> size *roam-file-byte-limit*)
                   (return-from roam-read-note (values nil 0 :oversized)))
                 (let ((fd descriptor))
                   (setf stream
                         (sb-sys:make-fd-stream
                          fd
                          :input t
                          :element-type '(unsigned-byte 8)
                          :buffering :full
                          :name (uiop:native-namestring pathname))
                         descriptor nil)
                   (let ((octets (make-array size
                                              :element-type '(unsigned-byte 8)))
                         (count 0))
                     (loop :while (< count size)
                           :do (let ((next (read-sequence octets stream
                                                          :start count)))
                         (when (= next count)
                           (return))
                                (setf count next)))
                     (let ((after (sb-posix:fstat fd)))
                       (cond
                         ((or (/= count size)
                              (not (equal (roam-stat-signature before)
                                          (roam-stat-signature after))))
                          (values nil size :changed))
                         ((find 0 octets)
                         (values nil size :binary))
                         (t
                          (handler-case
                              (values
                               (babel:octets-to-string octets
                                                       :encoding :utf-8
                                                       :errorp t)
                               size
                               :ok)
                            (error ()
                              (values nil size :unreadable))))))))))
           (error () (values nil 0 :unreadable)))
      (when stream
        (ignore-errors (close stream :abort t)))
      (when descriptor
        (ignore-errors (sb-posix:close descriptor))))))

(defun roam-normalize-newlines (text)
  (with-output-to-string (output)
    (loop :with index := 0
          :while (< index (length text))
          :for character := (char text index)
          :do (cond
                ((char= character #\Return)
                 (write-char #\Newline output)
                 (when (and (< (1+ index) (length text))
                            (char= (char text (1+ index)) #\Newline))
                   (incf index)))
                (t
                 (write-char character output)))
              (incf index))))

(defun roam-text-lines (text)
  (when text
    (let* ((normalized (roam-normalize-newlines text))
           (lines (uiop:split-string normalized :separator '(#\Newline))))
      (when (and lines
                 (plusp (length (first lines)))
                 (char= (char (first lines) 0) (code-char #xfeff)))
        (setf (first lines) (subseq (first lines) 1)))
      lines)))

(defun roam-safe-display-text (text)
  (map 'string
       (lambda (character)
         (if (and (graphic-char-p character)
                  (not (char= character #\Tab)))
             character
             #\Space))
       text))

(defun roam-valid-node-id-p (value)
  (and (plusp (length value))
       (<= (length value) *roam-metadata-value-limit*)
       (every (lambda (character)
                (and (graphic-char-p character)
                     (not (member character
                                  '(#\Space #\Tab #\[ #\])))))
              value)))

(defun make-roam-node
    (&key id kind pathname relative-path line level title aliases tags modified-at)
  (%make-roam-node
   :id id
   :kind kind
   :pathname pathname
   :relative-path relative-path
   :line line
   :level level
   :title (roam-safe-display-text title)
   :aliases (mapcar #'roam-safe-display-text aliases)
   :tags (mapcar #'roam-safe-display-text tags)
   :modified-at modified-at))

(defun roam-org-keyword-value (line keyword)
  (let* ((line (string-left-trim '(#\Space #\Tab) line))
         (prefix (format nil "#+~a" keyword))
         (colon (position #\: line)))
    (when (and colon
               (string-equal prefix line :end2 colon))
      (let ((value (string-trim '(#\Space #\Tab)
                                (subseq line (1+ colon)))))
        (and (<= (length value) *roam-metadata-value-limit*) value)))))

(defun roam-valid-org-tag-p (tag)
  (and (plusp (length tag))
       (every (lambda (character)
                (or (alphanumericp character)
                    (member character '(#\_ #\@ #\# #\%))))
              tag)))

(defun roam-parse-org-tags (value)
  (let ((value (string-trim '(#\Space #\Tab) value)))
    (when (and (<= (length value) *roam-metadata-value-limit*)
               (> (length value) 2)
               (char= (char value 0) #\:)
               (char= (char value (1- (length value))) #\:))
      (let ((tags (uiop:split-string
                   (subseq value 1 (1- (length value)))
                   :separator '(#\:))))
        (and (every #'roam-valid-org-tag-p tags)
             (subseq tags 0 (min 64 (length tags))))))))

(defun roam-org-heading-fields (line)
  "Return heading level, normalized title, and local tags for LINE."
  (alexandria:when-let ((level (org-heading-level-from-line line)))
    (let* ((body (string-left-trim
                  '(#\Space #\Tab)
                  (subseq line (position-if-not
                                (lambda (character) (char= character #\*))
                                line))))
           (tags nil))
      (let* ((body-end (string-right-trim '(#\Space #\Tab) body))
             (tag-start (position-if
                         (lambda (character)
                           (member character '(#\Space #\Tab)))
                         body-end :from-end t))
             (candidate (subseq body-end (if tag-start (1+ tag-start) 0)))
             (parsed-tags (roam-parse-org-tags candidate)))
        (when parsed-tags
          (setf tags parsed-tags
                body (if tag-start
                         (string-right-trim '(#\Space #\Tab)
                                            (subseq body-end 0 tag-start))
                         ""))))
      (let ((todo-seen-p nil)
            (comment-seen-p nil)
            (priority-seen-p nil))
        (loop
          (let* ((end (or (position-if
                           (lambda (character)
                             (member character '(#\Space #\Tab)))
                           body)
                          (length body)))
                 (token (subseq body 0 end))
                 (rest (string-left-trim '(#\Space #\Tab)
                                         (subseq body end))))
            (cond
              ((and (not todo-seen-p)
                    (member token *org-todo-keywords* :test #'string=))
               (setf todo-seen-p t body rest))
              ((and (not comment-seen-p) (string= token "COMMENT"))
               (setf comment-seen-p t body rest))
              ((and (not priority-seen-p)
                    (= 4 (length token))
                    (char= (char token 0) #\[)
                    (char= (char token 1) #\#)
                    (alphanumericp (char token 2))
                    (char= (char token 3) #\]))
               (setf priority-seen-p t body rest))
              (t (return)))))
        (values level (string-trim '(#\Space #\Tab) body) tags)))))

(defun roam-org-property-fields (line)
  (when (and (> (length line) 2) (char= (char line 0) #\:))
    (alexandria:when-let ((end (position #\: line :start 1)))
      (let ((name (subseq line 1 end)))
        (when (and (plusp (length name))
                   (every (lambda (character)
                            (or (alphanumericp character)
                                (member character '(#\_ #\-))))
                          name))
          (let ((value (string-trim '(#\Space #\Tab)
                                    (subseq line (1+ end)))))
            (when (<= (length value) *roam-metadata-value-limit*)
              (values (string-upcase name) value t))))))))

(defun roam-org-aliases (value)
  "Parse Org's quoted or bare ROAM_ALIASES tokens without invoking READ."
  (let ((aliases '())
        (index 0)
        (length (length value))
        (valid-p t))
    (labels ((skip-space ()
               (loop :while (and (< index length)
                                 (member (char value index) '(#\Space #\Tab)))
                     :do (incf index)))
             (read-token ()
               (let ((output (make-string-output-stream))
                     (quote (and (< index length)
                                 (find (char value index) '(#\' #\"))))
                     (closed-p nil)
                     (escaped nil))
                 (when quote (incf index))
                 (loop :while (< index length)
                       :for character := (char value index)
                       :do (incf index)
                           (cond
                             (escaped
                              (write-char character output)
                              (setf escaped nil))
                             ((char= character #\\)
                              (setf escaped t))
                             ((and quote (char= character quote))
                              (setf closed-p t)
                              (return))
                             ((and (null quote)
                                   (member character '(#\Space #\Tab)))
                              (return))
                             (t
                              (write-char character output))))
                 (when (or escaped (and quote (not closed-p)))
                   (setf valid-p nil))
                 (get-output-stream-string output))))
      (loop
        (skip-space)
        (when (>= index length) (return))
        (let ((alias (read-token)))
          (unless (zerop (length alias))
            (push alias aliases)))))
    (when valid-p
      (setf aliases (nreverse aliases))
      (subseq aliases 0 (min 64 (length aliases))))))

(defun roam-org-property-drawer (lines start)
  "Parse a complete property drawer at START.
Returns one unique ID, aliases, the next line index, and validity."
  (unless (and (< start (length lines))
               (string-equal ":PROPERTIES:" (aref lines start)))
    (return-from roam-org-property-drawer (values nil nil start nil)))
  (let ((id nil)
        (id-count 0)
        (aliases '())
        (alias-seen (make-hash-table :test #'equal)))
    (loop :for index :from (1+ start) :below (length lines)
          :for line := (aref lines index)
          :do (when (string-equal ":END:" line)
                (return-from roam-org-property-drawer
                  (values (and (= 1 id-count) id)
                          (nreverse aliases)
                          (1+ index)
                          (and (= 1 id-count) id))))
              (multiple-value-bind (name value present-p)
                  (roam-org-property-fields line)
                (unless present-p
                  (return-from roam-org-property-drawer
                    (values nil nil start nil)))
                (cond
                  ((string= name "ID")
                   (incf id-count)
                   (if (and (= 1 id-count) (roam-valid-node-id-p value))
                       (setf id value)
                       (setf id nil)))
                  ((and (string= name "ROAM_ALIASES")
                        (plusp (length value)))
                   (dolist (alias (roam-org-aliases value))
                     (when (and (< (length aliases) 64)
                                (not (gethash alias alias-seen)))
                       (setf (gethash alias alias-seen) t)
                       (push alias aliases)))))))
    (values nil nil start nil)))

(defun roam-org-planning-line-p (line)
  (cl-ppcre:scan "(?i)^(?:CLOSED|SCHEDULED|DEADLINE):" line))

(defun roam-org-heading-drawer-start (lines heading-index)
  (loop :for index :from (1+ heading-index) :below (length lines)
        :for line := (aref lines index)
        :while (roam-org-planning-line-p line)
        :finally (return
                   (and (< index (length lines))
                        (string-equal ":PROPERTIES:" (aref lines index))
                        index))))

(defun roam-heading-effective-tags (file-tags inherited-tags local-tags)
  (let ((tags '())
        (seen (make-hash-table :test #'equal)))
    (dolist (source (list file-tags inherited-tags local-tags))
      (dolist (tag source)
        (when (and (< (length tags) 64) (not (gethash tag seen)))
          (setf (gethash tag seen) t)
          (push tag tags))))
    (nreverse tags)))

(defun roam-org-nodes (pathname relative lines modified-at)
  (let ((lines (coerce lines 'vector))
        (file-title nil)
        (file-tags nil)
        (file-id nil)
        (file-aliases nil)
        (heading-stack '())
        (heading-nodes '())
        (open-block-type nil)
        (seen-heading-p nil)
        (file-drawer-eligible-p t)
        (index 0))
    (loop :while (< index (length lines))
          :for line := (aref lines index)
          :for marker := (org-block-marker line)
          :do
             (cond
               (open-block-type
                (when (and marker
                           (eq (car marker) :end)
                           (string= (cdr marker) open-block-type))
                  (setf open-block-type nil)))
               ((and marker (eq (car marker) :begin))
                (setf file-drawer-eligible-p nil)
                (setf open-block-type (cdr marker)))
               ((org-heading-level-from-line line)
                (setf seen-heading-p t)
                (multiple-value-bind (level title local-tags)
                    (roam-org-heading-fields line)
                  (loop :while (and heading-stack
                                    (>= (caar heading-stack) level))
                        :do (pop heading-stack))
                  (let ((effective-tags
                          (roam-heading-effective-tags
                           file-tags
                           (and heading-stack (cdar heading-stack))
                           local-tags))
                        (drawer-start
                          (roam-org-heading-drawer-start lines index)))
                    (when drawer-start
                      (multiple-value-bind (id aliases next valid-p)
                          (roam-org-property-drawer lines drawer-start)
                        (when (and valid-p
                                   (plusp (length title))
                                   (<= (length title)
                                       *roam-metadata-value-limit*))
                          (push
                           (make-roam-node
                            :id id
                            :kind :org-heading
                            :pathname pathname
                            :relative-path relative
                            :line (1+ index)
                            :level level
                            :title title
                            :aliases aliases
                            :tags effective-tags
                            :modified-at modified-at)
                           heading-nodes))
                        (setf index (max index (1- next)))))
                    (push (cons level effective-tags) heading-stack))))
               ((not seen-heading-p)
                (unless file-title
                  (alexandria:when-let
                      ((value (roam-org-keyword-value line "title")))
                    (unless (zerop (length value))
                      (setf file-title value))))
                (unless file-tags
                  (alexandria:when-let
                      ((value (roam-org-keyword-value line "filetags")))
                    (setf file-tags (roam-parse-org-tags value))))
                (when (and file-drawer-eligible-p
                           (null file-id)
                           (string-equal ":PROPERTIES:" line))
                  (multiple-value-bind (id aliases next valid-p)
                      (roam-org-property-drawer lines index)
                    (when valid-p
                      (setf file-id id
                            file-aliases aliases
                            index (max index (1- next))))))
                (unless (zerop (length (string-trim '(#\Space #\Tab) line)))
                  (setf file-drawer-eligible-p nil))))
             (incf index))
    (let ((file-node
            (and file-id file-title
                 (make-roam-node
                  :id file-id
                  :kind :org-file
                  :pathname pathname
                  :relative-path relative
                  :line 1
                  :level nil
                  :title file-title
                  :aliases file-aliases
                  :tags file-tags
                  :modified-at modified-at))))
      (if file-node
          (cons file-node (nreverse heading-nodes))
          (nreverse heading-nodes)))))

(defun roam-yaml-unquote (value)
  (let* ((value (string-trim '(#\Space #\Tab) value))
         (length (length value)))
    (cond
      ((> length *roam-metadata-value-limit*) nil)
      ((zerop length) "")
      ((= length 1)
       (and (not (member (char value 0) '(#\' #\"))) value))
      (t
       (let ((first (char value 0))
             (last (char value (1- length))))
         (cond
           ((and (char= first #\') (char= last #\'))
            (cl-ppcre:regex-replace-all
             "''" (subseq value 1 (1- length)) "'"))
           ((and (char= first #\") (char= last #\"))
            (let ((output (make-string-output-stream))
                  (escaped nil))
              (loop :for character :across (subseq value 1 (1- length))
                    :do (cond
                          (escaped
                           (write-char
                            (case character
                              (#\n #\Newline)
                              (#\r #\Return)
                              (#\t #\Tab)
                              (t character))
                            output)
                           (setf escaped nil))
                          ((char= character #\\)
                           (setf escaped t))
                          (t
                           (write-char character output))))
              (and (not escaped) (get-output-stream-string output))))
           ((or (member first '(#\' #\"))
                (member last '(#\' #\")))
            nil)
           (t value)))))))

(defun roam-yaml-comma-values (value)
  (let ((values '())
        (current (make-string-output-stream))
        (quote nil)
        (escaped nil))
    (labels ((finish ()
               (let ((item (roam-yaml-unquote
                            (get-output-stream-string current))))
                 (when (and item (plusp (length item)))
                   (push item values)))
               (setf current (make-string-output-stream))))
      (loop :for character :across value
            :do (cond
                  (escaped
                   (write-char character current)
                   (setf escaped nil))
                  ((and quote (char= character #\\) (char= quote #\"))
                   (write-char character current)
                   (setf escaped t))
                  ((and quote (char= character quote))
                   (write-char character current)
                   (setf quote nil))
                  ((and (null quote) (member character '(#\' #\")))
                   (write-char character current)
                   (setf quote character))
                  ((and (null quote) (char= character #\,))
                   (finish))
                  (t
                   (write-char character current))))
      (when quote
        (return-from roam-yaml-comma-values nil))
      (finish)
      (nreverse values))))

(defun roam-yaml-key-value (line)
  (unless (or (zerop (length line))
              (member (char line 0) '(#\Space #\Tab)))
    (alexandria:when-let ((colon (position #\: line)))
      (let ((key (subseq line 0 colon)))
        (when (and (plusp (length key))
                   (every (lambda (character)
                            (or (alphanumericp character)
                                (member character '(#\_ #\-))))
                          key))
          (values key
                  (string-trim '(#\Space #\Tab)
                               (subseq line (1+ colon)))))))))

(defun roam-markdown-aliases (value)
  (let ((value (string-trim '(#\Space #\Tab) value)))
    (when (and (<= (length value) *roam-metadata-value-limit*)
               (> (length value) 1)
               (char= (char value 0) #\[)
               (char= (char value (1- (length value))) #\]))
      (let ((aliases (roam-yaml-comma-values
                      (subseq value 1 (1- (length value))))))
        (subseq aliases 0 (min 64 (length aliases)))))))

(defun roam-markdown-tag-character-p (character)
  (or (alphanumericp character) (member character '(#\_ #\-))))

(defun roam-markdown-tags (lines closing)
  "Extract bounded Zettlr #tag/@tag tokens from Markdown front matter."
  (let ((tags '()))
    (loop :for line :in (subseq lines 1 closing)
          :while (< (length tags) 64)
          :do (loop :with index := 0
                    :while (and (< index (length line))
                                (< (length tags) 64))
                    :for character := (char line index)
                    :do (if (and (member character '(#\# #\@))
                                 (< (1+ index) (length line))
                                 (roam-markdown-tag-character-p
                                  (char line (1+ index)))
                                 (or (zerop index)
                                     (not (roam-markdown-tag-character-p
                                           (char line (1- index))))))
                            (let ((end (or (position-if-not
                                            #'roam-markdown-tag-character-p
                                            line :start (1+ index))
                                           (length line))))
                              (when (<= (- end (1+ index))
                                        *roam-metadata-value-limit*)
                                (push (subseq line (1+ index) end) tags))
                              (setf index end))
                            (incf index))))
    (nreverse tags)))

(defun roam-markdown-metadata (lines)
  (unless (and lines (string= "---" (first lines)))
    (return-from roam-markdown-metadata (values nil nil nil nil)))
  (let ((closing
          (position-if (lambda (line)
                         (string= line "---"))
                       lines :start 1)))
    (unless closing
      (return-from roam-markdown-metadata (values nil nil nil nil)))
    (let ((id nil)
          (title nil)
          (aliases nil)
          (id-seen-p nil)
          (title-seen-p nil)
          (aliases-seen-p nil))
      (dolist (line (subseq lines 1 closing))
        (multiple-value-bind (key value) (roam-yaml-key-value line)
          (when key
            (cond
              ((and (not id-seen-p) (string-equal key "id"))
               (setf id-seen-p t)
               (when (roam-valid-node-id-p value)
                 (setf id value)))
              ((and (not title-seen-p) (string-equal key "title"))
               (setf title-seen-p t)
               (when (and (plusp (length value))
                          (<= (length value) *roam-metadata-value-limit*))
                 (setf title value)))
              ((and (not aliases-seen-p)
                    (string-equal key "ROAM_ALIASES"))
               (setf aliases-seen-p t
                     aliases (roam-markdown-aliases value)))))))
      (values id title (roam-markdown-tags lines closing) aliases))))

(defun roam-markdown-nodes (pathname relative lines modified-at)
  (multiple-value-bind (id title tags aliases)
      (roam-markdown-metadata lines)
    (when (and id title)
      (list
       (make-roam-node
        :id id
        :kind :markdown-file
        :pathname pathname
        :relative-path relative
        :line 1
        :level nil
        :title title
        :aliases aliases
        :tags tags
        :modified-at modified-at)))))

(defun roam-nodes-from-pathname (pathname root)
  (multiple-value-bind (text bytes status) (roam-read-note pathname root)
    (if (not (eq status :ok))
        (values nil bytes status)
        (let* ((relative (enough-namestring pathname root))
               (lines (roam-text-lines text))
               (extension (pathname-type pathname))
               (modified-at (or (ignore-errors (file-write-date pathname)) 0)))
          (values
           (cond
             ((and extension (string-equal extension "org"))
              (roam-org-nodes pathname relative lines modified-at))
             ((and extension (string-equal extension "md"))
              (roam-markdown-nodes pathname relative lines modified-at))
             (t nil))
           bytes
           :ok)))))

(defun note-nodes ()
  "Return a bounded immutable snapshot of current Org-roam/md-roam nodes."
  (let* ((root (ignore-errors (truename (roam-directory))))
         (pathnames (and root (roam-listed-pathnames))))
    (unless root
      (return-from note-nodes nil))
    (when (> (length pathnames) *roam-file-count-limit*)
      (editor-error "Roam index exceeds the ~d-file safety limit."
                    *roam-file-count-limit*))
    (let ((nodes '())
          (node-count 0)
          (total-bytes 0)
          (skipped 0))
      (dolist (pathname pathnames)
        (multiple-value-bind (file-nodes bytes status)
            (roam-nodes-from-pathname pathname root)
          (incf total-bytes bytes)
          (when (> total-bytes *roam-total-byte-limit*)
            (editor-error "Roam index exceeds the ~d-byte safety limit."
                          *roam-total-byte-limit*))
          (if (eq status :ok)
              (dolist (node file-nodes)
                (push node nodes)
                (incf node-count))
              (incf skipped))
          (when (> node-count *roam-node-count-limit*)
            (editor-error "Roam index exceeds the ~d-node safety limit."
                          *roam-node-count-limit*))))
      (when (plusp skipped)
        (message "Roam index skipped ~d unreadable, changed, binary, or oversized file~:p."
                 skipped))
      (sort nodes
            (lambda (left right)
              (or (> (roam-node-modified-at left)
                     (roam-node-modified-at right))
                  (and (= (roam-node-modified-at left)
                          (roam-node-modified-at right))
                       (or (string-lessp (roam-node-relative-path left)
                                        (roam-node-relative-path right))
                           (and (string= (roam-node-relative-path left)
                                         (roam-node-relative-path right))
                                (< (roam-node-line left)
                                   (roam-node-line right)))))))))))

(defun note-files ()
  "Unique relative paths of all indexed Org and Markdown roam nodes."
  (remove-duplicates (mapcar #'roam-node-relative-path (note-nodes))
                     :test #'string=))

(defun roam-format-field (value width)
  (let ((display-width (lem/common/character:string-width value)))
    (cond
      ((> display-width width)
       (subseq value 0 (lem/common/character:wide-index value width)))
      ((< display-width width)
       (concatenate 'string value (make-string (- width display-width)
                                                :initial-element #\Space)))
      (t value))))

(defun roam-node-tag-text (node)
  (format nil "~{#~a~^ ~}" (roam-node-tags node)))

(defun roam-node-prompt-text (node)
  (roam-safe-display-text (roam-node-relative-path node)))

(defun roam-node-search-text (node)
  (format nil "~a ~a ~a ~{~a~^ ~} ~a"
          (roam-node-prompt-text node)
          (roam-node-title node)
          (roam-node-id node)
          (roam-node-aliases node)
          (roam-node-tag-text node)))

(defun roam-completion-item (node selected-cell)
  (with-point ((start (lem/prompt-window::current-prompt-start-point))
               (end (buffer-end-point (current-buffer))))
    (let ((node node))
      (lem/completion-mode:make-completion-item
       :label (roam-format-field (roam-node-prompt-text node) 30)
       :insert-text (roam-node-prompt-text node)
       :filter-text (roam-node-search-text node)
       :detail (format nil ":: ~a ~a~a"
                       (roam-node-title node)
                       (roam-format-field (roam-node-tag-text node) 10)
                       (if (eq (roam-node-kind node) :org-heading)
                           (format nil " L~d" (roam-node-line node))
                           ""))
       :start start
       :end end
       :accept-action (lambda () (setf (car selected-cell) node))))))

(defun roam-completion-items (nodes input selected-cell)
  (let ((filtered
          (prescient-filter input nodes
                            :key #'roam-node-search-text
                            :category :roam
                            :rank-p nil)))
    (mapcar (lambda (node) (roam-completion-item node selected-cell))
            (completion-sort-candidates
             filtered :key #'roam-node-prompt-text))))

(defun roam-refresh-completion ()
  (if lem/completion-mode::*completion-context*
      (lem/completion-mode:completion-refresh)
      (lem/prompt-window::open-prompt-completion)))

(define-command roam-delete-previous-char () ()
  "Delete one prompt character and reopen completion after zero matches."
  (delete-previous-char 1)
  (roam-refresh-completion))

(defparameter *roam-prompt-keymap*
  (let ((keymap (make-keymap :description "Roam node prompt")))
    (define-key keymap 'delete-previous-char 'roam-delete-previous-char)
    (define-key keymap "Backspace" 'roam-delete-previous-char)
    (define-key keymap "C-h" 'roam-delete-previous-char)
    keymap))

(defun roam-unique-node-for-prompt-text (input nodes)
  (let ((match nil))
    (dolist (node nodes match)
      (when (string= input (roam-node-prompt-text node))
        (when match
          (return-from roam-unique-node-for-prompt-text nil))
        (setf match node)))))

(defun roam-new-title-input-p (input nodes)
  "Whether INPUT is a bounded nonblank title with no matching existing node."
  (and (stringp input)
       (plusp (length (string-trim '(#\Space #\Tab) input)))
       (<= (length input) *roam-metadata-value-limit*)
       (null (prescient-filter input nodes
                               :key #'roam-node-search-text
                               :category :roam
                               :rank-p nil))))

(defun prompt-for-note (prompt)
  (let ((nodes (note-nodes)))
    (let ((selected-cell (list nil)))
      (let ((input
              (prompt-for-string
               prompt
               :completion-function
               (lambda (input)
                 (roam-completion-items nodes input selected-cell))
               :test-function
               (lambda (input)
                 (or (and (car selected-cell)
                          (string= input
                                   (roam-node-prompt-text
                                    (car selected-cell))))
                     (setf (car selected-cell)
                           (roam-unique-node-for-prompt-text input nodes))
                     (roam-new-title-input-p input nodes)))
               :history-symbol 'lem-yath-roam
               :special-keymap *roam-prompt-keymap*)))
        (values (car selected-cell) nodes
                (and (null (car selected-cell)) input))))))

(defun roam-ensure-target-buffer-current (node)
  (alexandria:when-let
      ((buffer (ignore-errors (find-file-buffer (roam-node-pathname node)))))
    (when (buffer-modified-p buffer)
      (editor-error
       "The selected roam note has unsaved changes; save it and reopen the picker."))
    (unless (eql (buffer-last-write-date buffer)
                 (ignore-errors (file-write-date (roam-node-pathname node))))
      (editor-error
       "The selected roam note changed on disk; revert it and reopen the picker."))))

(defun roam-resolve-node (node)
  "Reparse NODE's captured file and resolve its current unique ID."
  (roam-ensure-target-buffer-current node)
  (let ((root (ignore-errors (truename (roam-directory)))))
    (unless (and root (roam-path-in-root-p (roam-node-pathname node) root))
      (editor-error "The selected roam note no longer exists under the roam root."))
    (multiple-value-bind (nodes bytes status)
        (roam-nodes-from-pathname (roam-node-pathname node) root)
      (declare (ignore bytes))
      (unless (eq status :ok)
        (editor-error "The selected roam note could not be read safely."))
      (let ((matches
              (remove-if-not
               (lambda (candidate)
                 (and (eq (roam-node-kind candidate) (roam-node-kind node))
                      (string= (roam-node-id candidate) (roam-node-id node))))
               nodes)))
        (cond
          ((null matches)
           (editor-error "The selected roam node changed; reopen the picker."))
          ((cdr matches)
           (editor-error "The selected roam node ID is ambiguous in its file."))
          (t (first matches)))))))

(defun roam-visit-node (node)
  (let ((current (roam-resolve-node node)))
    (find-file (roam-node-pathname current))
    (goto-line (roam-node-line current))))

(defun roam-escape-link-text (text characters)
  (with-output-to-string (output)
    (loop :for character :across text
          :when (member character characters)
            :do (write-char #\\ output)
          :do (write-char character output))))

(define-command lem-yath-roam-random () ()
  "Open a random roam note (org-roam-node-random)."
  (let ((nodes (note-nodes)))
    (if nodes
        (roam-visit-node (elt nodes (random (length nodes))))
        (message "No notes found under ~a" (roam-directory)))))
