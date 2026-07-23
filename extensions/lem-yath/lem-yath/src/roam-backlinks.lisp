;;;; Persistent Org-roam-style backlinks over the bounded note corpus.
;;;;
;;;; The panel owns no database.  One asynchronous immutable snapshot resolves
;;;; Org ID links, md-roam title/alias wiki links, and ROAM_REFS citation/URL
;;;; reflinks, then cheap post-command lookups keep the visible panel on the
;;;; nearest node at point.  `g' rebuilds the snapshot from descriptor-verified
;;;; files.

(in-package :lem-yath)

(defparameter *roam-backlink-buffer-name* "*org-roam*")
(defparameter *roam-backlink-occurrence-limit* 100000)
(defparameter *roam-backlink-ref-per-node-limit* 64)
(defparameter *roam-backlink-ref-entry-limit* 100000)
(defparameter *roam-backlink-preview-character-limit* 16384)
(defparameter *roam-backlink-render-character-limit* (* 1024 1024))

(defstruct (roam-backlink-occurrence
            (:constructor make-roam-backlink-occurrence))
  target-id source-node pathname line column link-text outline preview)

(defstruct (roam-backlink-span (:constructor make-roam-backlink-span))
  node start-line end-line)

(defstruct (roam-backlink-file (:constructor make-roam-backlink-file))
  pathname kind lines nodes spans)

(defstruct (roam-backlink-snapshot
            (:constructor make-roam-backlink-snapshot))
  nodes id-index file-index backlinks reflinks skipped-files)

(defstruct (roam-backlink-heading
            (:constructor make-roam-backlink-heading))
  level title node line)

(defvar *lem-yath-roam-backlink-mode-keymap*
  (make-keymap :description '*lem-yath-roam-backlink-mode-keymap*))

(defvar *lem-yath-roam-backlink-vi-keymap*
  (make-keymap :description '*lem-yath-roam-backlink-vi-keymap*))

(defun roam-backlink-buffer-live-p (buffer)
  (and buffer (member buffer (buffer-list) :test #'eq)))

(defun roam-backlink-path-key (pathname)
  (uiop:native-namestring pathname))

(defun roam-backlink-path-kind (pathname)
  (let ((extension (pathname-type pathname)))
    (cond ((and extension (string-equal extension "org")) :org)
          ((and extension (string-equal extension "md")) :markdown))))

(defun roam-backlink-file-node (nodes kind)
  (find kind nodes :key #'roam-node-kind))

(defun roam-backlink-node-at-line (nodes line)
  (find line nodes :key #'roam-node-line :test #'=))

(defun roam-backlink-org-spans (lines nodes)
  "Return file and ID-heading ownership spans for one Org note."
  (let ((line-nodes (make-hash-table :test #'eql))
        (active '())
        (spans '())
        (open-block nil)
        (line-count (length lines)))
    (dolist (node nodes)
      (when (eq (roam-node-kind node) :org-heading)
        (setf (gethash (roam-node-line node) line-nodes) node)))
    (loop :for index :from 0 :below line-count
          :for line := (aref lines index)
          :for marker := (org-block-marker line)
          :do
             (cond
               (open-block
                (when (and marker (eq (car marker) :end)
                           (string= (cdr marker) open-block))
                  (setf open-block nil)))
               ((and marker (eq (car marker) :begin))
                (setf open-block (cdr marker)))
               (t
                (alexandria:when-let
                    ((level (org-heading-level-from-line line)))
                  (loop :while (and active
                                    (>= (roam-node-level
                                         (roam-backlink-span-node
                                          (first active)))
                                        level))
                        :do (let ((span (pop active)))
                              (setf (roam-backlink-span-end-line span) index)))
                  (alexandria:when-let
                      ((node (gethash (1+ index) line-nodes)))
                    (let ((span
                            (make-roam-backlink-span
                             :node node :start-line (1+ index)
                             :end-line line-count)))
                      (push span active)
                      (push span spans)))))))
    (alexandria:when-let ((file-node
                           (roam-backlink-file-node nodes :org-file)))
      (push (make-roam-backlink-span
             :node file-node :start-line 1 :end-line line-count)
            spans))
    (nreverse spans)))

(defun roam-backlink-make-spans (kind lines nodes)
  (ecase kind
    (:org (roam-backlink-org-spans lines nodes))
    (:markdown
     (alexandria:when-let
         ((node (roam-backlink-file-node nodes :markdown-file)))
       (list (make-roam-backlink-span
              :node node :start-line 1 :end-line (length lines)))))))

(defun roam-backlink-index-push (table key value)
  (push value (gethash key table)))

(defun roam-backlink-unique-index-value (table key)
  (let ((values (gethash key table)))
    (and values (null (cdr values)) (first values))))

(defun roam-backlink-add-name (table name node)
  (when (plusp (length name))
    (let ((values (gethash name table)))
      (unless (member node values :test #'eq)
        (push node (gethash name table))))))

(defun roam-backlink-collapse-space (text)
  (with-output-to-string (output)
    (loop :with pending-space := nil
          :for character :across text
          :do (if (member character '(#\Space #\Tab #\Newline #\Return))
                  (setf pending-space t)
                  (progn
                    (when (and pending-space (plusp (file-position output)))
                      (write-char #\Space output))
                    (setf pending-space nil)
                    (write-char character output))))))

(defun roam-backlink-unescape-wiki-name (text)
  (with-output-to-string (output)
    (loop :with escaped := nil
          :for character :across text
          :do (cond
                (escaped
                 (write-char character output)
                 (setf escaped nil))
                ((char= character #\\)
                 (setf escaped t))
                (t (write-char character output)))
          :finally (when escaped (write-char #\\ output)))))

(defun roam-backlink-resolve-wiki-target (name id-index name-index)
  (let* ((name (roam-backlink-unescape-wiki-name name))
         (collapsed (roam-backlink-collapse-space name)))
    (or (roam-backlink-unique-index-value name-index name)
        (and (not (string= name collapsed))
             (roam-backlink-unique-index-value name-index collapsed))
        (roam-backlink-unique-index-value id-index name))))

(defun roam-backlink-safe-preview (text)
  (let* ((text (string-trim '(#\Space #\Tab #\Newline #\Return) text))
         (truncated (> (length text) *roam-backlink-preview-character-limit*))
         (text (if truncated
                   (subseq text 0 *roam-backlink-preview-character-limit*)
                   text)))
    (with-output-to-string (output)
      (loop :for character :across text
            :do (cond
                  ((or (char= character #\Newline)
                       (char= character #\Tab))
                   (write-char character output))
                  ((graphic-char-p character)
                   (write-char character output))
                  (t (write-char #\Space output))))
      (when truncated
        (terpri output)
        (write-string "…" output)))))

(defun roam-backlink-lines-string (lines start end)
  (with-output-to-string (output)
    (loop :for index :from start :below end
          :do (when (> index start) (terpri output))
              (write-string (aref lines index) output))))

(defun roam-backlink-org-metadata-end (lines start end &optional file-level-p)
  "Return the first body line after simple Org planning/properties metadata."
  (let ((index start))
    (loop
      (loop :while (and (< index end)
                        (or (zerop (length
                                    (string-trim '(#\Space #\Tab)
                                                 (aref lines index))))
                            (roam-org-planning-line-p (aref lines index))))
            :do (incf index))
      (cond
        ((and (< index end)
              (string-equal ":PROPERTIES:" (aref lines index)))
         (incf index)
         (loop :while (< index end)
               :for line := (aref lines index)
               :do (incf index)
               :when (string-equal ":END:" line) :do (return)))
        ((and file-level-p (< index end)
              (alexandria:starts-with-subseq
               "#+" (string-left-trim '(#\Space #\Tab)
                                       (aref lines index))
               :test #'char-equal)
              (null (org-block-marker (aref lines index))))
         (incf index))
        (t (return))))
    index))

(defun roam-backlink-org-preview (lines heading line-index)
  (let* ((start (if heading (roam-backlink-heading-line heading) 0))
         (body-start (if heading (1+ start) start))
         (end (length lines))
         (open-block nil))
    (loop :for index :from body-start :below (length lines)
          :for line := (aref lines index)
          :for marker := (org-block-marker line)
          :do (cond
                (open-block
                 (when (and marker (eq (car marker) :end)
                            (string= (cdr marker) open-block))
                   (setf open-block nil)))
                ((and marker (eq (car marker) :begin))
                 (setf open-block (cdr marker)))
                ((org-heading-level-from-line line)
                 (setf end index)
                 (return))))
    (let ((metadata-end
            (roam-backlink-org-metadata-end
             lines body-start end (null heading))))
      ;; A malformed or metadata-only section still exposes the exact link line.
      (when (>= metadata-end end)
        (setf metadata-end (min line-index (max body-start (1- end)))
              end (min end (1+ line-index))))
      (roam-backlink-safe-preview
       (roam-backlink-lines-string lines metadata-end end)))))

(defun roam-backlink-markdown-body-start (lines)
  (if (and (plusp (length lines))
           (string= "---" (string-trim '(#\Space #\Tab) (aref lines 0))))
      (loop :for index :from 1 :below (length lines)
            :for line := (string-trim '(#\Space #\Tab) (aref lines index))
            :when (or (string= line "---") (string= line "..."))
              :do (return (1+ index))
            :finally (return (length lines)))
      0))

(defun roam-backlink-markdown-heading-p (line)
  (let ((trimmed (string-left-trim '(#\Space #\Tab) line)))
    (and (> (length trimmed) 2)
         (char= (char trimmed 0) #\#)
         (position #\Space trimmed))))

(defun roam-backlink-markdown-preview (lines line-index)
  (let ((body-start (roam-backlink-markdown-body-start lines))
        (start nil)
        (end (length lines)))
    (loop :for index :from body-start :to (min line-index
                                                (1- (length lines)))
          :when (roam-backlink-markdown-heading-p (aref lines index))
            :do (setf start (1+ index)))
    (setf start (or start body-start))
    (loop :for index :from (max start (1+ line-index)) :below (length lines)
          :when (roam-backlink-markdown-heading-p (aref lines index))
            :do (setf end index) (return))
    (roam-backlink-safe-preview
     (roam-backlink-lines-string lines start end))))

(defun roam-backlink-comment-line-p (line)
  (let ((trimmed (string-left-trim '(#\Space #\Tab) line)))
    (or (string= trimmed "#")
        (and (> (length trimmed) 1)
             (char= (char trimmed 0) #\#)
             (member (char trimmed 1) '(#\Space #\Tab))))))

(defun roam-backlink-org-id-links (line)
  "Return (COLUMN TARGET LITERAL) triples for bracketed Org ID links."
  (let ((links '()) (index 0))
    (loop
      (let ((start (search "[[id:" line :start2 index :test #'char-equal)))
        (unless start (return))
        (let* ((target-start (+ start 5))
               (target-end (position #\] line :start target-start)))
          (if (null target-end)
              (return)
              (let* ((raw (subseq line target-start target-end))
                     (option (search "::" raw))
                     (target (if option (subseq raw 0 option) raw))
                     (direct-end (and (< (1+ target-end) (length line))
                                      (char= (char line (1+ target-end)) #\])))
                     (description-p (and (< (1+ target-end) (length line))
                                         (char= (char line (1+ target-end)) #\[)))
                     (link-end
                       (cond
                         (direct-end (+ target-end 2))
                         (description-p
                          (alexandria:when-let
                              ((close (search "]]" line
                                              :start2 (+ target-end 2))))
                            (+ close 2))))))
                (when (and link-end (roam-valid-node-id-p target))
                  (push (list start target (subseq line start link-end)) links))
                (setf index (max (1+ start) (or link-end (1+ target-end)))))))))
    (nreverse links)))

(defun roam-backlink-wiki-links (line)
  "Return (COLUMN NAME LITERAL) triples for md-roam wiki links."
  (let ((links '()) (index 0))
    (loop
      (let ((start (search "[[" line :start2 index)))
        (unless start (return))
        (let ((end (search "]]" line :start2 (+ start 2))))
          (unless end (return))
          (let ((name (subseq line (+ start 2) end)))
            (when (plusp (length name))
              (push (list start name (subseq line start (+ end 2))) links)))
          (setf index (+ end 2)))))
    (nreverse links)))

(defun roam-backlink-citation-key-character-p (character)
  (or (alphanumericp character)
      (member character '(#\- #\_ #\+ #\: #\. #\/))))

(defun roam-backlink-balanced-bracket-end (line start)
  (loop :with depth := 0
        :for index :from start :below (length line)
        :for character := (char line index)
        :do (cond
              ((char= character #\[) (incf depth))
              ((char= character #\])
               (decf depth)
               (when (zerop depth) (return (1+ index)))))))

(defun roam-backlink-citation-links (line)
  "Return (COLUMN KEY LITERAL) triples for Org cite elements in LINE."
  (let ((links '()) (index 0))
    (loop
      (let ((start (search "[cite:" line :start2 index :test #'char-equal)))
        (unless start (return))
        (let ((end (roam-backlink-balanced-bracket-end line start)))
          (unless end (return))
          (let ((literal (subseq line start end))
                (seen (make-hash-table :test #'equal))
                (cursor (+ start 6)))
            (loop :while (< cursor end)
                  :for at := (position #\@ line :start cursor :end end)
                  :while at
                  :for key-start := (1+ at)
                  :for key-end := (or (position-if-not
                                        #'roam-backlink-citation-key-character-p
                                        line :start key-start :end end)
                                       end)
                  :do (when (and (> key-end key-start)
                                 (not (gethash (subseq line key-start key-end)
                                               seen)))
                        (let ((key (subseq line key-start key-end)))
                          (setf (gethash key seen) t)
                          (push (list start key literal) links)))
                      (setf cursor (max (1+ at) key-end)))
          (setf index end)))))
    (nreverse links)))

(defun roam-backlink-markdown-citations (line)
  "Return (COLUMN KEY LITERAL) triples for md-roam Pandoc citations."
  (let ((links '()) (index 0))
    (loop :while (< index (length line))
          :for at := (position #\@ line :start index)
          :while at
          :for key-start := (1+ at)
          :for key-end := (or (position-if-not
                                #'roam-backlink-citation-key-character-p
                                line :start key-start)
                               (length line))
          :do (when (and (> key-end key-start)
                         (or (zerop at)
                             (not (alphanumericp (char line (1- at))))))
                (push (list at
                            (subseq line key-start key-end)
                            (subseq line at key-end))
                      links))
              (setf index (max (1+ at) key-end)))
    (nreverse links)))

(defun roam-backlink-http-ref-p (text)
  (or (alexandria:starts-with-subseq "http://" text :test #'char-equal)
      (alexandria:starts-with-subseq "https://" text :test #'char-equal)))

(defun roam-backlink-normalized-refs (value)
  "Parse the bounded ROAM_REFS subset present in the configured corpus."
  (let ((refs '())
        (seen (make-hash-table :test #'equal)))
    (dolist (token (roam-org-aliases value))
      (let ((keys
              (cond
                ((and (> (length token) 1) (char= (char token 0) #\@))
                 (list (cons :cite (subseq token 1))))
                ((alexandria:starts-with-subseq
                  "[cite:" token :test #'char-equal)
                 (mapcar (lambda (link) (cons :cite (second link)))
                         (roam-backlink-citation-links token)))
                ((roam-backlink-http-ref-p token)
                 (list (cons :link token))))))
        (dolist (key keys)
          (when (and (< (length refs) *roam-backlink-ref-per-node-limit*)
                     (plusp (length (cdr key)))
                     (not (gethash key seen)))
            (setf (gethash key seen) t)
            (push key refs)))))
    (nreverse refs)))

(defun roam-backlink-link-literal (line start ref)
  "Return the source column and exact link literal containing REF."
  (cond
    ((and (>= start 2) (string= "[[" line :start2 (- start 2) :end2 start))
     (alexandria:if-let ((end (search "]]" line :start2 (+ start (length ref)))))
       (values (- start 2) (subseq line (- start 2) (+ end 2)))
       (values start ref)))
    ((and (>= start 2) (string= "](" line :start2 (- start 2) :end2 start))
     (let ((open (position #\[ line :end (- start 2) :from-end t))
           (close (position #\) line :start (+ start (length ref)))))
       (if (and open close)
           (values open (subseq line open (1+ close)))
           (values start ref))))
    (t (values start ref))))

(defun roam-backlink-balanced-url-end (line start)
  "Return the end of one URL, preserving balanced parentheses."
  (let ((depth 0))
    (loop :for index :from start :below (length line)
          :for character := (char line index)
          :do (cond
                ((or (member character
                             '(#\Space #\Tab #\Newline #\Return
                               #\[ #\] #\< #\> #\"))
                     (not (graphic-char-p character)))
                 (return index))
                ((char= character #\()
                 (incf depth))
                ((char= character #\))
                 (if (plusp depth)
                     (decf depth)
                     (return index))))
          :finally (return (length line)))))

(defun roam-backlink-url-end (line start)
  (cond
    ((and (>= start 2) (string= "[[" line :start2 (- start 2) :end2 start))
     (or (position #\] line :start start) (length line)))
    ((and (>= start 2) (string= "](" line :start2 (- start 2) :end2 start))
     (roam-backlink-balanced-url-end line start))
    (t
     (let ((end (roam-backlink-balanced-url-end line start)))
       (loop :while (and (> end start)
                         (member (char line (1- end))
                                 '(#\. #\, #\; #\! #\?)))
             :do (decf end))
       end))))

(defun roam-backlink-reference-links (line ref-index)
  "Return (KEY COLUMN LITERAL) triples for indexed HTTP(S) refs in LINE."
  (let ((links '()) (index 0))
    (loop :while (< index (length line))
          :for http := (search "http://" line :start2 index :test #'char-equal)
          :for https := (search "https://" line :start2 index :test #'char-equal)
          :for start := (cond ((and http https) (min http https))
                              (http http)
                              (https https))
          :while start
          :for end := (roam-backlink-url-end line start)
          :for ref := (subseq line start end)
          :for key := (cons :link ref)
          :do (when (gethash key ref-index)
                (multiple-value-bind (column literal)
                    (roam-backlink-link-literal line start ref)
                  (push (list key column literal) links)))
              (setf index (max (1+ start) end)))
    (nreverse links)))

(defun roam-backlink-heading-outline (stack)
  (mapcar #'roam-backlink-heading-title (reverse stack)))

(defun roam-backlink-heading-source (stack file-node)
  (or (loop :for heading :in stack
            :when (roam-backlink-heading-node heading)
              :return (roam-backlink-heading-node heading))
      file-node))

(defun roam-backlink-drawer-ref-value (lines start)
  (when (and start (< start (length lines))
             (string-equal ":PROPERTIES:" (aref lines start)))
    (loop :for index :from (1+ start) :below (length lines)
          :for line := (aref lines index)
          :do (when (string-equal ":END:" line) (return nil))
              (multiple-value-bind (name value present-p)
                  (roam-org-property-fields line)
                (unless present-p (return nil))
                (when (string= name "ROAM_REFS") (return value))))))

(defun roam-backlink-org-ref-pairs (file)
  (let* ((lines (roam-backlink-file-lines file))
         (nodes (roam-backlink-file-nodes file))
         (pairs '()))
    (alexandria:when-let ((file-node
                           (roam-backlink-file-node nodes :org-file)))
      (let ((first-content
              (position-if (lambda (line)
                             (plusp (length
                                     (string-trim '(#\Space #\Tab) line))))
                           lines)))
        (alexandria:when-let*
            ((value (roam-backlink-drawer-ref-value lines first-content)))
          (dolist (ref (roam-backlink-normalized-refs value))
            (push (cons file-node ref) pairs)))))
    (dolist (node nodes)
      (when (eq (roam-node-kind node) :org-heading)
        (alexandria:when-let*
            ((drawer (roam-org-heading-drawer-start
                      lines (1- (roam-node-line node))))
             (value (roam-backlink-drawer-ref-value lines drawer)))
          (dolist (ref (roam-backlink-normalized-refs value))
            (push (cons node ref) pairs)))))
    (nreverse pairs)))

(defun roam-backlink-markdown-ref-pairs (file)
  (let* ((lines (roam-backlink-file-lines file))
         (node (roam-backlink-file-node
                (roam-backlink-file-nodes file) :markdown-file))
         (closing (and (> (length lines) 1)
                       (position-if
                        (lambda (line)
                          (or (string= line "---") (string= line "...")))
                        lines :start 1))))
    (when (and node closing)
      (loop :for index :from 1 :below closing
            :for line := (aref lines index)
            :do (multiple-value-bind (key value)
                    (roam-yaml-key-value line)
                  (when (and key (string-equal key "ROAM_REFS"))
                    (return
                      (mapcar (lambda (ref) (cons node ref))
                              (roam-backlink-normalized-refs value)))))))))

(defun roam-backlink-file-ref-pairs (file)
  (ecase (roam-backlink-file-kind file)
    (:org (roam-backlink-org-ref-pairs file))
    (:markdown (roam-backlink-markdown-ref-pairs file))))

(defun roam-backlink-source-occurrence
    (file source target-id line column literal outline preview)
  (make-roam-backlink-occurrence
   :target-id target-id
   :source-node source
   :pathname (roam-backlink-file-pathname file)
   :line line
   :column column
   :link-text literal
   :outline outline
   :preview preview))

(defun roam-backlink-parse-org-file
    (file ref-index add-backlink add-reflink)
  (let* ((lines (roam-backlink-file-lines file))
         (nodes (roam-backlink-file-nodes file))
         (file-node (roam-backlink-file-node nodes :org-file))
         (line-nodes (make-hash-table :test #'eql))
         (headings '())
         (open-block nil)
         (property-drawer-p nil))
    (dolist (node nodes)
      (when (eq (roam-node-kind node) :org-heading)
        (setf (gethash (roam-node-line node) line-nodes) node)))
    (loop :for index :from 0 :below (length lines)
          :for line := (aref lines index)
          :for marker := (org-block-marker line)
          :do
             (cond
               (open-block
                (when (and marker (eq (car marker) :end)
                           (string= (cdr marker) open-block))
                  (setf open-block nil)))
               ((and marker (eq (car marker) :begin))
                (setf open-block (cdr marker)))
               (t
                (alexandria:when-let
                    ((level (org-heading-level-from-line line)))
                  (loop :while (and headings
                                    (>= (roam-backlink-heading-level
                                         (first headings))
                                        level))
                        :do (pop headings))
                  (multiple-value-bind (parsed-level title tags)
                      (roam-org-heading-fields line)
                    (declare (ignore tags))
                    (push (make-roam-backlink-heading
                           :level parsed-level :title title
                           :node (gethash (1+ index) line-nodes)
                           :line index)
                          headings)))
                (cond
                  ((string-equal ":PROPERTIES:" line)
                   (setf property-drawer-p t))
                  ((and property-drawer-p (string-equal ":END:" line))
                   (setf property-drawer-p nil))
                  ((or property-drawer-p
                       (roam-backlink-comment-line-p line)
                       (alexandria:starts-with-subseq
                        "#+" (string-left-trim '(#\Space #\Tab) line)
                        :test #'char-equal)))
                  (t
                   (let ((source
                           (roam-backlink-heading-source headings file-node))
                         (outline (roam-backlink-heading-outline headings)))
                     (when source
                       (let ((preview
                               (roam-backlink-org-preview
                                lines (first headings) index)))
                         (dolist (link (roam-backlink-org-id-links line))
                           (funcall
                            add-backlink
                            (roam-backlink-source-occurrence
                             file source (second link) (1+ index)
                             (first link) (third link) outline preview)))
                         (dolist (link (roam-backlink-citation-links line))
                           (dolist (target
                                    (gethash (cons :cite (second link))
                                             ref-index))
                             (funcall
                              add-reflink
                              (roam-backlink-source-occurrence
                               file source (roam-node-id target) (1+ index)
                               (first link) (third link) outline preview))))
                         (dolist (link
                                  (roam-backlink-reference-links
                                   line ref-index))
                           (dolist (target (gethash (first link) ref-index))
                             (funcall
                              add-reflink
                              (roam-backlink-source-occurrence
                               file source (roam-node-id target) (1+ index)
                               (second link) (third link) outline preview))))))))))))))

(defun roam-backlink-parse-markdown-file
    (file id-index name-index ref-index add-backlink add-reflink)
  (let* ((lines (roam-backlink-file-lines file))
         (source (roam-backlink-file-node
                  (roam-backlink-file-nodes file) :markdown-file))
         (start (roam-backlink-markdown-body-start lines)))
    (when source
      (loop :for index :from start :below (length lines)
            :for line := (aref lines index)
            :do (let ((preview
                        (roam-backlink-markdown-preview lines index)))
                  (dolist (link (roam-backlink-wiki-links line))
                    (alexandria:when-let
                        ((target (roam-backlink-resolve-wiki-target
                                  (second link) id-index name-index)))
                      (funcall
                       add-backlink
                       (roam-backlink-source-occurrence
                        file source (roam-node-id target) (1+ index)
                        (first link) (third link) nil preview))))
                  (dolist (link (roam-backlink-markdown-citations line))
                    (dolist (target
                             (gethash (cons :cite (second link)) ref-index))
                      (funcall
                       add-reflink
                       (roam-backlink-source-occurrence
                        file source (roam-node-id target) (1+ index)
                        (first link) (third link) nil preview))))
                  (dolist (link
                           (roam-backlink-reference-links line ref-index))
                    (dolist (target (gethash (first link) ref-index))
                      (funcall
                       add-reflink
                       (roam-backlink-source-occurrence
                        file source (roam-node-id target) (1+ index)
                        (second link) (third link) nil preview)))))))))

(defun roam-backlink-occurrence-less-p (left right)
  (let ((left-node (roam-backlink-occurrence-source-node left))
        (right-node (roam-backlink-occurrence-source-node right)))
    (cond
      ((not (string= (roam-node-title left-node)
                     (roam-node-title right-node)))
       (string-lessp (roam-node-title left-node)
                     (roam-node-title right-node)))
      ((not (string= (roam-node-relative-path left-node)
                     (roam-node-relative-path right-node)))
       (string-lessp (roam-node-relative-path left-node)
                     (roam-node-relative-path right-node)))
      ((/= (roam-backlink-occurrence-line left)
           (roam-backlink-occurrence-line right))
       (< (roam-backlink-occurrence-line left)
          (roam-backlink-occurrence-line right)))
      (t
       (< (roam-backlink-occurrence-column left)
          (roam-backlink-occurrence-column right))))))

(defun roam-backlink-build-snapshot ()
  "Build one bounded backlink snapshot without opening editor buffers."
  (let* ((root (ignore-errors (truename (roam-directory))))
         (pathnames (and root (roam-listed-pathnames))))
    (unless root
      (return-from roam-backlink-build-snapshot
        (make-roam-backlink-snapshot
         :nodes nil :id-index (make-hash-table :test #'equal)
         :file-index (make-hash-table :test #'equal)
         :backlinks (make-hash-table :test #'equal)
         :reflinks (make-hash-table :test #'equal) :skipped-files 0)))
    (let ((files '())
          (nodes '())
          (total-bytes 0)
          (node-count 0)
          (skipped 0))
      (dolist (pathname pathnames)
        (multiple-value-bind (text bytes status) (roam-read-note pathname root)
          (incf total-bytes bytes)
          (when (> total-bytes *roam-total-byte-limit*)
            (editor-error "Roam index exceeds the ~d-byte safety limit."
                          *roam-total-byte-limit*))
          (if (not (eq status :ok))
              (incf skipped)
              (let* ((kind (roam-backlink-path-kind pathname))
                     (line-list (roam-text-lines text))
                     (lines (coerce line-list 'vector))
                     (file-nodes (and kind
                                      (roam-nodes-from-lines
                                       pathname root line-list))))
                (incf node-count (length file-nodes))
                (when (> node-count *roam-node-count-limit*)
                  (editor-error "Roam index exceeds the ~d-node safety limit."
                                *roam-node-count-limit*))
                (setf nodes (nconc nodes file-nodes))
                (when kind
                  (push (make-roam-backlink-file
                         :pathname pathname :kind kind :lines lines
                         :nodes file-nodes
                         :spans (roam-backlink-make-spans
                                 kind lines file-nodes))
                        files))))))
      (let ((id-index (make-hash-table :test #'equal))
            (name-index (make-hash-table :test #'equal))
            (ref-index (make-hash-table :test #'equal))
            (file-index (make-hash-table :test #'equal))
            (backlinks (make-hash-table :test #'equal))
            (reflinks (make-hash-table :test #'equal))
            (ref-entry-count 0)
            (occurrence-count 0))
        (dolist (node nodes)
          (roam-backlink-index-push id-index (roam-node-id node) node)
          (roam-backlink-add-name name-index (roam-node-title node) node)
          (dolist (alias (roam-node-aliases node))
            (roam-backlink-add-name name-index alias node)))
        (dolist (file files)
          (setf (gethash (roam-backlink-path-key
                         (roam-backlink-file-pathname file))
                         file-index)
                file)
          (dolist (pair (roam-backlink-file-ref-pairs file))
            (incf ref-entry-count)
            (when (> ref-entry-count *roam-backlink-ref-entry-limit*)
              (editor-error
               "Roam index exceeds the ~d-reference safety limit."
               *roam-backlink-ref-entry-limit*))
            (roam-backlink-index-push ref-index (cdr pair) (car pair))))
        (labels ((record-occurrence (table occurrence)
                   ;; Missing and globally ambiguous destinations cannot be
                   ;; displayed safely as one current Org-roam node.
                   (when (roam-backlink-unique-index-value
                          id-index
                          (roam-backlink-occurrence-target-id occurrence))
                     (incf occurrence-count)
                     (when (> occurrence-count
                              *roam-backlink-occurrence-limit*)
                       (editor-error
                        "Roam index exceeds the ~d-link occurrence safety limit."
                        *roam-backlink-occurrence-limit*))
                     (roam-backlink-index-push
                      table
                      (roam-backlink-occurrence-target-id occurrence)
                      occurrence)))
                 (add-backlink (occurrence)
                   (record-occurrence backlinks occurrence))
                 (add-reflink (occurrence)
                   (record-occurrence reflinks occurrence)))
          (dolist (file files)
            (ecase (roam-backlink-file-kind file)
              (:org
               (roam-backlink-parse-org-file
                file ref-index #'add-backlink #'add-reflink))
              (:markdown
               (roam-backlink-parse-markdown-file
                file id-index name-index ref-index
                #'add-backlink #'add-reflink)))))
        (maphash (lambda (id occurrences)
                   (setf (gethash id backlinks)
                         (sort occurrences #'roam-backlink-occurrence-less-p)))
                 backlinks)
        (maphash (lambda (id occurrences)
                   (setf (gethash id reflinks)
                         (sort occurrences #'roam-backlink-occurrence-less-p)))
                 reflinks)
        (make-roam-backlink-snapshot
         :nodes nodes :id-index id-index :file-index file-index
         :backlinks backlinks :reflinks reflinks :skipped-files skipped)))))

(defun roam-backlink-snapshot-node-at-point (snapshot buffer)
  (let ((filename (ignore-errors (buffer-filename buffer))))
    (when filename
      (alexandria:when-let*
          ((pathname (ignore-errors (truename filename)))
           (file (gethash (roam-backlink-path-key pathname)
                          (roam-backlink-snapshot-file-index snapshot))))
        (let ((line (line-number-at-point (buffer-point buffer)))
              (best nil))
          (dolist (span (roam-backlink-file-spans file) best)
            (when (<= (roam-backlink-span-start-line span)
                      line
                      (roam-backlink-span-end-line span))
              (when (or (null best)
                        (> (roam-backlink-span-start-line span)
                           (roam-backlink-span-start-line best)))
                (setf best span))))
          (and best (roam-backlink-span-node best)))))))

(defun roam-backlink-snapshot-file-for-buffer (snapshot buffer)
  (alexandria:when-let*
      ((filename (ignore-errors (buffer-filename buffer)))
       (pathname (ignore-errors (truename filename))))
    (gethash (roam-backlink-path-key pathname)
             (roam-backlink-snapshot-file-index snapshot))))

(defun roam-backlink-panel-visible-p (&optional
                                        (buffer
                                          (get-buffer
                                           *roam-backlink-buffer-name*)))
  (let ((window (frame-rightside-window (current-frame))))
    (and buffer window (eq (window-buffer window) buffer))))

(defun roam-backlink-panel-width ()
  (let ((width (display-width)))
    (max 20 (min (round (* width 0.4)) (max 20 (- width 20))))))

(defun roam-backlink-show-panel (buffer)
  (let* ((width (roam-backlink-panel-width))
         (window (make-rightside-window buffer :width width)))
    ;; `make-rightside-window' reuses an existing side window without applying
    ;; WIDTH, so restore the configured 0.4 width explicitly.
    (window-set-size window width (window-height window))
    (window-set-pos window (- (display-width) width) (window-y window))
    window))

(defun roam-backlink-outline-text (occurrence)
  (let ((outline (roam-backlink-occurrence-outline occurrence)))
    (if outline (format nil "~{~a~^ > ~}" outline) "Top")))

(defun roam-backlink-insert-occurrence
    (point occurrence remaining &optional reflink-p)
  (let ((text
          (format nil "~a (~a)~%~a~%~%"
                  (roam-node-title
                   (roam-backlink-occurrence-source-node occurrence))
                  (roam-backlink-outline-text occurrence)
                  (roam-backlink-occurrence-preview occurrence))))
    (when (> (length text) remaining)
      (setf text (concatenate
                  'string (subseq text 0 (max 0 (- remaining 2)))
                  (format nil "…~%"))))
    (with-point ((start point))
      (insert-string point text)
      (put-text-property start point :roam-backlink occurrence)
      (when reflink-p
        (put-text-property start point :roam-reflink t)))
    (length text)))

(defun roam-backlink-insert-section
    (point heading occurrences remaining &optional reflink-p)
  (let ((header (format nil "~a~%~%" heading)))
    (when (> (length header) remaining)
      (return-from roam-backlink-insert-section 0))
    (insert-string point header)
    (decf remaining (length header))
    (dolist (occurrence occurrences remaining)
      (when (<= remaining 2)
        (when (plusp remaining)
          (insert-string point (subseq (format nil "…~%") 0 remaining)))
        (return 0))
      (decf remaining
            (roam-backlink-insert-occurrence
             point occurrence remaining reflink-p)))))

(defun roam-backlink-render-message (buffer text key)
  (with-buffer-read-only buffer nil
    (erase-buffer buffer)
    (insert-string (buffer-end-point buffer) text))
  (setf (buffer-value buffer 'lem-yath-roam-backlink-target-key) key
        (buffer-read-only-p buffer) t)
  (buffer-start (buffer-point buffer))
  (buffer-unmark buffer)
  (redraw-display))

(defun roam-backlink-render-node (buffer snapshot node)
  (let* ((id (roam-node-id node))
         (id-nodes (gethash id (roam-backlink-snapshot-id-index snapshot)))
         (occurrences (and (null (cdr id-nodes))
                           (gethash id
                                    (roam-backlink-snapshot-backlinks
                                     snapshot))))
         (reflinks (and (null (cdr id-nodes))
                        (gethash id
                                 (roam-backlink-snapshot-reflinks snapshot))))
         (key (list id (roam-node-relative-path node) (roam-node-line node))))
    (with-buffer-read-only buffer nil
      (erase-buffer buffer)
      (let ((point (buffer-end-point buffer)))
        (insert-string point (format nil "~a~%~%" (roam-node-title node)))
        (cond
          ((cdr id-nodes)
           (insert-string
            point
            (format nil
                    "Links unavailable: this node ID is globally ambiguous.~%")))
          ((and (null occurrences) (null reflinks))
           (insert-string point (format nil "No backlinks or reflinks.~%")))
          (t
           (let ((remaining (- *roam-backlink-render-character-limit*
                               (- (position-at-point
                                   (buffer-end-point buffer))
                                  (position-at-point
                                   (buffer-start-point buffer))))))
             (when occurrences
               (setf remaining
                     (roam-backlink-insert-section
                      point "Backlinks:" occurrences remaining)))
             (when (and reflinks (plusp remaining))
               (roam-backlink-insert-section
                point "Reflinks:" reflinks remaining t)))))))
    (setf (buffer-value buffer 'lem-yath-roam-backlink-target-key) key
          (buffer-read-only-p buffer) t)
    (buffer-start (buffer-point buffer))
    (buffer-unmark buffer)
    (redraw-display)))

(defun roam-backlink-render-for-origin (panel origin &optional force)
  (let ((snapshot (buffer-value panel 'lem-yath-roam-backlink-snapshot)))
    (when (and snapshot (roam-backlink-buffer-live-p origin))
      (cond
        ((buffer-modified-p origin)
         (let ((key (list :modified (buffer-filename origin))))
           (when (or force
                     (not (equal key
                                 (buffer-value
                                  panel
                                  'lem-yath-roam-backlink-target-key))))
             (roam-backlink-render-message
              panel
              (format nil
                      "Org-roam links~%~%Save this note to refresh its link snapshot.~%")
              key))))
        (t
         (alexandria:when-let
             ((node (roam-backlink-snapshot-node-at-point snapshot origin)))
           (let ((key (list (roam-node-id node)
                            (roam-node-relative-path node)
                            (roam-node-line node))))
             (when (or force
                       (not (equal key
                                   (buffer-value
                                    panel
                                    'lem-yath-roam-backlink-target-key))))
               (roam-backlink-render-node panel snapshot node)))))))))

(defun roam-backlink-generation (buffer)
  (or (buffer-value buffer 'lem-yath-roam-backlink-generation) 0))

(defun roam-backlink-next-generation (buffer)
  (setf (buffer-value buffer 'lem-yath-roam-backlink-generation)
        (1+ (roam-backlink-generation buffer))))

(defun roam-backlink-scan-worker (buffer generation)
  (multiple-value-bind (snapshot failure)
      (handler-case (values (roam-backlink-build-snapshot) nil)
        (error (condition) (values nil condition)))
    (send-event
     (lambda ()
       (roam-backlink-finish-scan buffer generation snapshot failure)))))

(defun roam-backlink-launch-scan (buffer generation)
  (setf (buffer-value buffer 'lem-yath-roam-backlink-scan-running) t)
  (handler-case
      (bt2:make-thread
       (lambda () (roam-backlink-scan-worker buffer generation))
       :name (format nil "lem-yath/roam-backlinks-~d" generation))
    (error (condition)
      (setf (buffer-value buffer 'lem-yath-roam-backlink-scan-running) nil)
      (roam-backlink-render-message
       buffer (format nil "Backlink index could not start: ~a~%" condition)
       (list :failure generation)))))

(defun roam-backlink-finish-scan (buffer generation snapshot failure)
  (when (roam-backlink-buffer-live-p buffer)
    (setf (buffer-value buffer 'lem-yath-roam-backlink-scan-running) nil)
    (cond
      ((buffer-value buffer 'lem-yath-roam-backlink-refresh-pending)
       (setf (buffer-value buffer 'lem-yath-roam-backlink-refresh-pending) nil)
       (roam-backlink-launch-scan buffer (roam-backlink-generation buffer)))
      ((= generation (roam-backlink-generation buffer))
       (if failure
           (roam-backlink-render-message
            buffer (format nil "Backlink index failed: ~a~%" failure)
            (list :failure generation))
           (progn
             (setf (buffer-value buffer 'lem-yath-roam-backlink-snapshot)
                   snapshot)
             (alexandria:when-let
                 ((origin (buffer-value
                           buffer 'lem-yath-roam-backlink-origin-buffer)))
               (roam-backlink-render-for-origin buffer origin t))
             (when (plusp
                    (roam-backlink-snapshot-skipped-files snapshot))
               (message "Roam backlink index skipped ~d unsafe file~:p."
                        (roam-backlink-snapshot-skipped-files snapshot)))))))))

(defun roam-backlink-start-scan (buffer origin origin-window)
  (setf (buffer-value buffer 'lem-yath-roam-backlink-origin-buffer) origin
        (buffer-value buffer 'lem-yath-roam-backlink-origin-window)
        origin-window)
  (let ((generation (roam-backlink-next-generation buffer)))
    (roam-backlink-render-message buffer (format nil "Indexing backlinks…~%")
                                  (list :indexing generation))
    (if (buffer-value buffer 'lem-yath-roam-backlink-scan-running)
        (setf (buffer-value buffer 'lem-yath-roam-backlink-refresh-pending) t)
        (progn
          (setf (buffer-value buffer 'lem-yath-roam-backlink-refresh-pending) nil)
          (roam-backlink-launch-scan buffer generation)))))

(defun roam-backlink-source-current-p (occurrence)
  (let* ((node (roam-backlink-occurrence-source-node occurrence))
         (current (roam-resolve-node node))
         (root (ignore-errors (truename (roam-directory)))))
    (declare (ignore current))
    (multiple-value-bind (text bytes status)
        (roam-read-note (roam-backlink-occurrence-pathname occurrence) root)
      (declare (ignore bytes))
      (and (eq status :ok)
           (let* ((lines (roam-text-lines text))
                  (line-index (1- (roam-backlink-occurrence-line occurrence)))
                  (column (roam-backlink-occurrence-column occurrence))
                  (literal (roam-backlink-occurrence-link-text occurrence)))
             (and (<= 0 line-index)
                  (< line-index (length lines))
                  (let ((line (elt lines line-index)))
                    (and (<= (+ column (length literal)) (length line))
                         (string= literal line
                                  :start2 column
                                  :end2 (+ column (length literal)))))))))))

(defun roam-backlink-live-origin-window (panel)
  (let ((window (buffer-value panel 'lem-yath-roam-backlink-origin-window)))
    (and window (member window (window-list) :test #'eq) window)))

(defun roam-backlink-visit-occurrence (panel occurrence)
  (unless (roam-backlink-source-current-p occurrence)
    (editor-error "This backlink changed on disk; press g to refresh."))
  (let ((window (or (roam-backlink-live-origin-window panel)
                    (current-window))))
    (with-current-window window
      (find-file (roam-backlink-occurrence-pathname occurrence))
      (goto-line (roam-backlink-occurrence-line occurrence))
      (move-to-column (current-point)
                      (roam-backlink-occurrence-column occurrence)))
    (setf (buffer-value panel 'lem-yath-roam-backlink-origin-window) window
          (buffer-value panel 'lem-yath-roam-backlink-origin-buffer)
          (window-buffer window))
    (roam-backlink-render-for-origin panel (window-buffer window) t)))

(defun roam-backlink-close-panel (&optional
                                    (panel
                                      (get-buffer
                                       *roam-backlink-buffer-name*)))
  (when (and panel (roam-backlink-panel-visible-p panel))
    (let ((destination (or (roam-backlink-live-origin-window panel)
                           (first (window-list)))))
      ;; Lem refuses to delete the selected side window.  Restore a main
      ;; window first, matching quit-window's observable behavior in Emacs.
      (when destination
        (switch-to-window destination))
      (delete-rightside-window))))

(defun roam-backlink-kill-buffer-cleanup (&optional
                                           (buffer (current-buffer)))
  (when (roam-backlink-buffer-live-p buffer)
    (roam-backlink-next-generation buffer)
    (setf (buffer-value buffer 'lem-yath-roam-backlink-refresh-pending) nil)
    (when (roam-backlink-panel-visible-p buffer)
      (roam-backlink-close-panel buffer))))

(define-major-mode lem-yath-roam-backlink-mode nil
    (:name "Org-Roam"
     :keymap *lem-yath-roam-backlink-mode-keymap*)
  (setf (buffer-read-only-p (current-buffer)) t)
  (buffer-disable-undo (current-buffer))
  (add-hook (variable-value 'kill-buffer-hook :buffer (current-buffer))
            'roam-backlink-kill-buffer-cleanup))

(defmethod lem-vi-mode/core:mode-specific-keymaps
    ((mode lem-yath-roam-backlink-mode))
  (declare (ignore mode))
  (unless (lem-yath-emacs-state-p)
    (list *lem-yath-roam-backlink-vi-keymap*)))

(define-command lem-yath-roam-backlink-visit () ()
  "Visit the exact source represented by the current backlink or reflink row."
  (let ((occurrence (text-property-at (current-point) :roam-backlink)))
    (if occurrence
        (roam-backlink-visit-occurrence (current-buffer) occurrence)
        (message "No Org-roam link on this line."))))

(define-command lem-yath-roam-backlink-refresh () ()
  "Rebuild the visible Org-roam link snapshot."
  (let* ((panel (current-buffer))
         (origin (buffer-value panel 'lem-yath-roam-backlink-origin-buffer))
         (window (buffer-value panel 'lem-yath-roam-backlink-origin-window)))
    (if (roam-backlink-buffer-live-p origin)
        (roam-backlink-start-scan panel origin window)
        (message "No live roam note owns this backlink panel."))))

(define-command lem-yath-roam-backlink-close () ()
  "Close the Org-roam backlink side window without killing its snapshot."
  (roam-backlink-close-panel (current-buffer)))

(define-command org-roam-buffer-toggle () ()
  "Toggle the persistent Org-roam backlink panel for the node at point."
  (let ((existing (get-buffer *roam-backlink-buffer-name*)))
    (if (and existing (roam-backlink-panel-visible-p existing))
        (roam-backlink-close-panel existing)
        (let* ((origin (current-buffer))
               (origin-window (current-window))
               (filename (ignore-errors (buffer-filename origin)))
               (root (ignore-errors (truename (roam-directory))))
               (pathname (and filename (ignore-errors (truename filename)))))
          (unless (and pathname root (roam-path-in-root-p pathname root))
            (editor-error "Open an Org-roam or md-roam note first."))
          (let ((panel (or existing
                           (make-buffer *roam-backlink-buffer-name*
                                        :enable-undo-p nil))))
            (unless (mode-active-p panel 'lem-yath-roam-backlink-mode)
              (change-buffer-mode panel 'lem-yath-roam-backlink-mode))
            (setf (buffer-directory panel) root
                  (buffer-value panel 'lem-yath-roam-backlink-origin-buffer)
                  origin
                  (buffer-value panel 'lem-yath-roam-backlink-origin-window)
                  origin-window)
            (roam-backlink-show-panel panel)
            (alexandria:when-let
                ((snapshot
                   (buffer-value panel 'lem-yath-roam-backlink-snapshot)))
              (roam-backlink-render-for-origin panel origin t))
            (roam-backlink-start-scan panel origin origin-window))))))

(define-key *lem-yath-roam-backlink-mode-keymap* "Return"
  'lem-yath-roam-backlink-visit)
(define-key *lem-yath-roam-backlink-mode-keymap* "g"
  'lem-yath-roam-backlink-refresh)
(define-key *lem-yath-roam-backlink-mode-keymap* "q"
  'lem-yath-roam-backlink-close)
(define-key *lem-yath-roam-backlink-vi-keymap* "Return"
  'lem-yath-roam-backlink-visit)
(define-key *lem-yath-roam-backlink-vi-keymap* "g"
  'lem-yath-roam-backlink-refresh)
(define-key *lem-yath-roam-backlink-vi-keymap* "q"
  'lem-yath-roam-backlink-close)

(defun roam-backlink-post-command ()
  "Redisplay the visible panel when point enters a different indexed node."
  (let ((panel (get-buffer *roam-backlink-buffer-name*))
        (origin (current-buffer)))
    (when (and panel
               (roam-backlink-panel-visible-p panel)
               (not (eq panel origin))
               (buffer-value panel 'lem-yath-roam-backlink-snapshot))
      (let ((snapshot
              (buffer-value panel 'lem-yath-roam-backlink-snapshot)))
        ;; Org-roam's redisplay hook is active only in roam-file buffers.
        ;; Prompt/help/scratch commands therefore retain the last valid node
        ;; and, critically, the main source window used by Return.
        (when (roam-backlink-snapshot-file-for-buffer snapshot origin)
          (setf (buffer-value panel 'lem-yath-roam-backlink-origin-buffer)
                origin
                (buffer-value panel 'lem-yath-roam-backlink-origin-window)
                (current-window))
          (roam-backlink-render-for-origin panel origin))))))

(defun roam-backlink-after-save (&optional (buffer (current-buffer)))
  "Refresh a visible backlink panel after saving a note in the roam root."
  (let ((panel (get-buffer *roam-backlink-buffer-name*)))
    (when (and panel
               (roam-backlink-panel-visible-p panel)
               (roam-backlink-buffer-live-p buffer))
      (alexandria:when-let*
          ((filename (ignore-errors (buffer-filename buffer)))
           (pathname (ignore-errors (truename filename)))
           (root (ignore-errors (truename (roam-directory)))))
        (when (and (roam-backlink-path-kind pathname)
                   (roam-path-in-root-p pathname root))
          (let* ((display-window
                   (find buffer (window-list)
                         :key #'window-buffer :test #'eq))
                 (origin
                   (or (and display-window buffer)
                       (buffer-value
                        panel 'lem-yath-roam-backlink-origin-buffer)))
                 (origin-window
                   (or display-window
                       (roam-backlink-live-origin-window panel))))
            (when (roam-backlink-buffer-live-p origin)
              (roam-backlink-start-scan panel origin origin-window))))))))

(defun roam-backlink-reload-cleanup ()
  (remove-hook *post-command-hook* 'roam-backlink-post-command)
  (remove-hook (variable-value 'after-save-hook :global t)
               'roam-backlink-after-save)
  (alexandria:when-let ((buffer (get-buffer *roam-backlink-buffer-name*)))
    (when (roam-backlink-panel-visible-p buffer)
      (ignore-errors (roam-backlink-close-panel buffer)))
    (ignore-errors
      (with-global-variable-value (kill-buffer-hook nil)
        (delete-buffer buffer)))))

(roam-backlink-reload-cleanup)
(add-hook *post-command-hook* 'roam-backlink-post-command -350)
(add-hook (variable-value 'after-save-hook :global t)
          'roam-backlink-after-save)
