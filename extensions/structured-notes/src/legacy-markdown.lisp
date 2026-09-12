(in-package #:lem-structured-notes)

(defclass legacy-markdown-provider (source-provider) ())

(defparameter +legacy-markdown-metadata-value-limit+ 4096)
(defparameter +legacy-markdown-list-limit+ 64)

(defmethod source-provider-format ((provider legacy-markdown-provider))
  (declare (ignore provider))
  :markdown)

(defmethod source-provider-profile ((provider legacy-markdown-provider))
  (declare (ignore provider))
  "legacy-roam/1")

(defmethod source-content-fingerprint
    ((provider legacy-markdown-provider) source)
  (declare (ignore provider))
  (require-non-empty-string source :invalid-legacy-markdown-source
                            "legacy Markdown source")
  source)

(defmethod source-metadata-fingerprint
    ((provider legacy-markdown-provider) source)
  (declare (ignore provider source))
  "inline-source/no-external-metadata")

(defun legacy-markdown-safe-text-p (value)
  (and (stringp value)
       (plusp (length value))
       (<= (length value) +legacy-markdown-metadata-value-limit+)
       (not (find-if (lambda (character)
                       (or (char= character #\Null)
                           (char= character #\Newline)
                           (char= character #\Return)))
                     value))))

(defun legacy-markdown-safe-id-p (value)
  (and (legacy-markdown-safe-text-p value)
       (every (lambda (character)
                (and (graphic-char-p character)
                     (not (member character '(#\Space #\Tab #\[ #\])))))
              value)))

(defun legacy-markdown-frontmatter-fields (lines end-index)
  (let ((fields nil)
        (seen (make-hash-table :test #'equal)))
    (dolist (line (subseq lines 1 end-index) (nreverse fields))
      (let ((text (source-line-text line)))
        (when (zerop (line-indentation text))
          (multiple-value-bind (key value) (simple-field text)
            (when key
              (let ((name (string-downcase key)))
                (when (member name
                              '("id" "title" "roam_aliases" "roam_refs")
                              :test #'string=)
                  (when (gethash name seen)
                    (model-error :duplicate-legacy-markdown-field name
                                 "legacy Markdown frontmatter contains a duplicate typed field"))
                  (setf (gethash name seen) t)
                  (push (cons name value) fields))))))))))

(defun legacy-markdown-field (name fields)
  (cdr (assoc name fields :test #'string=)))

(defun legacy-markdown-aliases (value)
  (when value
    (let* ((trimmed (trim-source-space value))
           (length (length trimmed)))
      (unless (and (<= length +legacy-markdown-metadata-value-limit+)
                   (> length 1)
                   (char= (char trimmed 0) #\[)
                   (char= (char trimmed (1- length)) #\]))
        (model-error :invalid-legacy-markdown-aliases value
                     "legacy Markdown ROAM_ALIASES must be one bounded YAML flow sequence"))
      (let ((aliases (comma-separated-scalars trimmed)))
        (unless (and (<= (length aliases) +legacy-markdown-list-limit+)
                     (every #'legacy-markdown-safe-text-p aliases))
          (model-error :invalid-legacy-markdown-aliases aliases
                       "legacy Markdown aliases exceed their shape or value boundary"))
        aliases))))

(defun legacy-markdown-shell-tokens (value)
  (let ((tokens nil)
        (index 0)
        (length (length value))
        (valid-p t))
    (labels ((skip-space ()
               (loop :while (and (< index length)
                                 (member (char value index) '(#\Space #\Tab)))
                     :do (incf index)))
             (read-token ()
               (let ((stream (make-string-output-stream))
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
                              (write-char character stream)
                              (setf escaped nil))
                             ((char= character #\\)
                              (setf escaped t))
                             ((and quote (char= character quote))
                              (setf closed-p t)
                              (return))
                             ((and (null quote)
                                   (member character '(#\Space #\Tab)))
                              (return))
                             (t (write-char character stream))))
                 (unless (and (not escaped)
                              (or (null quote) closed-p))
                   (setf valid-p nil))
                 (get-output-stream-string stream))))
      (loop
        (skip-space)
        (when (>= index length) (return))
        (let ((token (read-token)))
          (when (plusp (length token)) (push token tokens))))
      (unless valid-p
        (model-error :invalid-legacy-markdown-references value
                     "legacy Markdown ROAM_REFS contains malformed quoting"))
      (nreverse tokens))))

(defun legacy-markdown-citation-keys (token)
  (let ((keys nil)
        (index 0))
    (loop :while (< index (length token))
          :for at := (position #\@ token :start index)
          :while at
          :for start := (1+ at)
          :for end := (or (position-if-not #'node-citation-key-character-p
                                           token :start start)
                          (length token))
          :do (when (> end start) (push (subseq token start end) keys))
              (setf index (max (1+ at) end)))
    (nreverse keys)))

(defun legacy-markdown-references (value)
  (let ((references nil)
        (seen (make-hash-table :test #'equal)))
    (dolist (token (if value (legacy-markdown-shell-tokens value) nil))
      (let ((candidates
              (cond
                ((and (> (length token) 1)
                      (char= (char token 0) #\@))
                 (list (cons :citation (subseq token 1))))
                ((and (>= (length token) 6)
                      (string-equal "[cite:" token :end2 6))
                 (mapcar (lambda (key) (cons :citation key))
                         (legacy-markdown-citation-keys token)))
                ((or (and (>= (length token) 7)
                          (string-equal "http://" token :end2 7))
                     (and (>= (length token) 8)
                          (string-equal "https://" token :end2 8)))
                 (list (cons :url token))))))
        (dolist (candidate candidates)
          (when (and (< (length references) +legacy-markdown-list-limit+)
                     (not (gethash candidate seen)))
            (setf (gethash candidate seen) t)
            (push (make-node-reference :kind (car candidate)
                                       :value (cdr candidate))
                  references)))))
    (nreverse references)))

(defun legacy-markdown-tag-character-p (character)
  (or (alphanumericp character) (member character '(#\_ #\-))))

(defun legacy-markdown-tags (lines end-index)
  (let ((tags nil)
        (seen (make-hash-table :test #'equal)))
    (dolist (line (subseq lines 1 end-index) (nreverse tags))
      (let ((text (source-line-text line)) (index 0))
        (loop :while (and (< index (length text))
                          (< (length tags) +legacy-markdown-list-limit+))
              :for character := (char text index)
              :do
                 (if (and (member character '(#\# #\@))
                          (< (1+ index) (length text))
                          (legacy-markdown-tag-character-p
                           (char text (1+ index)))
                          (or (zerop index)
                              (not (legacy-markdown-tag-character-p
                                    (char text (1- index))))))
                     (let* ((start (1+ index))
                            (end
                              (or (position-if-not
                                   #'legacy-markdown-tag-character-p
                                   text :start start)
                                  (length text)))
                            (tag (subseq text start end)))
                       (when (and (<= (length tag)
                                      +legacy-markdown-metadata-value-limit+)
                                  (not (gethash tag seen)))
                         (setf (gethash tag seen) t)
                         (push tag tags))
                       (setf index end))
                     (incf index)))))))

(defun legacy-markdown-inner-frontmatter (source lines end-index)
  (let ((start (source-line-character-end (first lines)))
        (end (source-line-character-start (nth end-index lines))))
    (validate-lsm-extra-frontmatter-raw (subseq source start end))))

(defmethod parse-source ((provider legacy-markdown-provider) source
                         &key source-id revision)
  (unless (stringp source)
    (model-error :invalid-legacy-markdown-source source
                 "legacy Markdown provider parses string sources"))
  (require-non-empty-string source-id :invalid-source-id
                            "legacy Markdown source ID")
  (require-non-empty-string revision :invalid-source-revision
                            "legacy Markdown source revision")
  (let* ((lines (scan-source-lines source))
         (end-index (frontmatter-end-index lines)))
    (unless end-index
      (model-error :missing-legacy-markdown-frontmatter source-id
                   "legacy Markdown migration requires leading YAML frontmatter"))
    (let* ((fields (legacy-markdown-frontmatter-fields lines end-index))
           (id-value (legacy-markdown-field "id" fields))
           (title-value (legacy-markdown-field "title" fields))
           (id (and id-value (strip-scalar-quotes id-value)))
           (title (and title-value (strip-scalar-quotes title-value)))
           (aliases
             (legacy-markdown-aliases
              (legacy-markdown-field "roam_aliases" fields)))
           (references
             (legacy-markdown-references
              (legacy-markdown-field "roam_refs" fields)))
           (tags (legacy-markdown-tags lines end-index))
           (frontmatter
             (legacy-markdown-inner-frontmatter source lines end-index))
           (body-start
             (source-line-character-end (nth end-index lines)))
           (body (subseq source body-start))
           (byte-prefixes (source-byte-prefixes source)))
      (unless (legacy-markdown-safe-id-p id)
        (model-error :invalid-legacy-markdown-id id
                     "legacy Markdown migration requires one bounded roam node ID"))
      (unless (legacy-markdown-safe-text-p title)
        (model-error :invalid-legacy-markdown-title title
                     "legacy Markdown migration requires one bounded title"))
      (let* ((node
               (make-semantic-node
                :id id :level 1 :title title
                :aliases aliases :references references :tags tags
                :body
                (if (plusp (length body))
                    (list
                     (make-content-node
                      :kind :opaque :source-format :commonmark :raw body
                      :span
                      (make-source-span
                       :source-id source-id
                       :character-start body-start
                       :character-end (length source)
                       :byte-start (aref byte-prefixes body-start)
                       :byte-end (aref byte-prefixes (length source)))))
                    nil)
                :span
                (make-source-span
                 :source-id source-id
                 :character-start 0 :character-end (length source)
                 :byte-start 0
                 :byte-end (aref byte-prefixes (length source)))))
             (document
               (make-semantic-document
                :id id :source-uri source-id :format :markdown
                :profile "legacy-roam/1" :nodes (list node)
                :root-ids (list id) :newline (source-newline-style source)
                :source-revision revision
                :extensions (list (make-lsm-frontmatter-extension frontmatter)))))
        (make-source-snapshot
         :provider provider :source-id source-id :revision revision
         :document document :syntax-tree source
         :content-fingerprint (source-content-fingerprint provider source)
         :metadata-fingerprint (source-metadata-fingerprint provider source))))))
