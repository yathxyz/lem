;;;; Persistent Org-roam-style backlinks over the bounded note corpus.
;;;;
;;;; The panel owns no database.  One asynchronous immutable snapshot resolves
;;;; Org ID links and md-roam title/alias wiki links, then cheap post-command
;;;; lookups keep the visible panel on the nearest node at point.  `g' rebuilds
;;;; the snapshot from descriptor-verified files.

(in-package :lem-yath)

(defparameter *roam-backlink-buffer-name* "*org-roam*")
(defparameter *roam-backlink-occurrence-limit* 100000)
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
  nodes id-index file-index backlinks skipped-files)

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

(defun roam-backlink-heading-outline (stack)
  (mapcar #'roam-backlink-heading-title (reverse stack)))

(defun roam-backlink-heading-source (stack file-node)
  (or (loop :for heading :in stack
            :when (roam-backlink-heading-node heading)
              :return (roam-backlink-heading-node heading))
      file-node))

(defun roam-backlink-parse-org-file (file add-occurrence)
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
                       (dolist (link (roam-backlink-org-id-links line))
                         (funcall
                          add-occurrence
                          (make-roam-backlink-occurrence
                           :target-id (second link)
                           :source-node source
                           :pathname (roam-backlink-file-pathname file)
                           :line (1+ index)
                           :column (first link)
                           :link-text (third link)
                           :outline outline
                           :preview (roam-backlink-org-preview
                                     lines (first headings) index)))))))))))))

(defun roam-backlink-parse-markdown-file
    (file id-index name-index add-occurrence)
  (let* ((lines (roam-backlink-file-lines file))
         (source (roam-backlink-file-node
                  (roam-backlink-file-nodes file) :markdown-file))
         (start (roam-backlink-markdown-body-start lines)))
    (when source
      (loop :for index :from start :below (length lines)
            :for line := (aref lines index)
            :do (dolist (link (roam-backlink-wiki-links line))
                  (alexandria:when-let
                      ((target (roam-backlink-resolve-wiki-target
                                (second link) id-index name-index)))
                    (funcall
                     add-occurrence
                     (make-roam-backlink-occurrence
                      :target-id (roam-node-id target)
                      :source-node source
                      :pathname (roam-backlink-file-pathname file)
                      :line (1+ index)
                      :column (first link)
                      :link-text (third link)
                      :outline nil
                      :preview (roam-backlink-markdown-preview
                                lines index)))))))))

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
         :backlinks (make-hash-table :test #'equal) :skipped-files 0)))
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
            (file-index (make-hash-table :test #'equal))
            (backlinks (make-hash-table :test #'equal))
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
                file))
        (labels ((add-occurrence (occurrence)
                   ;; Missing and globally ambiguous destinations cannot be
                   ;; displayed safely as one current Org-roam node.
                   (when (roam-backlink-unique-index-value
                          id-index
                          (roam-backlink-occurrence-target-id occurrence))
                     (incf occurrence-count)
                     (when (> occurrence-count
                              *roam-backlink-occurrence-limit*)
                       (editor-error
                        "Roam index exceeds the ~d-backlink safety limit."
                        *roam-backlink-occurrence-limit*))
                     (roam-backlink-index-push
                      backlinks
                      (roam-backlink-occurrence-target-id occurrence)
                      occurrence))))
          (dolist (file files)
            (ecase (roam-backlink-file-kind file)
              (:org (roam-backlink-parse-org-file file #'add-occurrence))
              (:markdown
               (roam-backlink-parse-markdown-file
                file id-index name-index #'add-occurrence)))))
        (maphash (lambda (id occurrences)
                   (setf (gethash id backlinks)
                         (sort occurrences #'roam-backlink-occurrence-less-p)))
                 backlinks)
        (make-roam-backlink-snapshot
         :nodes nodes :id-index id-index :file-index file-index
         :backlinks backlinks :skipped-files skipped)))))

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

(defun roam-backlink-insert-occurrence (point occurrence remaining)
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
      (put-text-property start point :roam-backlink occurrence))
    (length text)))

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
                    "Backlinks unavailable: this node ID is globally ambiguous.~%")))
          ((null occurrences)
           (insert-string point (format nil "No backlinks.~%")))
          (t
           (insert-string point (format nil "Backlinks:~%~%"))
           (let ((remaining (- *roam-backlink-render-character-limit*
                               (- (position-at-point
                                   (buffer-end-point buffer))
                                  (position-at-point
                                   (buffer-start-point buffer))))))
             (dolist (occurrence occurrences)
               (when (<= remaining 2)
                 (insert-string point (format nil "…~%"))
                 (return))
               (decf remaining
                     (roam-backlink-insert-occurrence
                      point occurrence remaining))))))))
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
                      "Backlinks~%~%Save this note to refresh its backlink snapshot.~%")
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
  "Visit the exact source link represented by the current backlink row."
  (let ((occurrence (text-property-at (current-point) :roam-backlink)))
    (if occurrence
        (roam-backlink-visit-occurrence (current-buffer) occurrence)
        (message "No backlink on this line."))))

(define-command lem-yath-roam-backlink-refresh () ()
  "Rebuild the visible Org-roam backlink snapshot."
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
