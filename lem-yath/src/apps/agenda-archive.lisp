;;;; Durable default Org archiving from the bounded agenda view.

(in-package :lem-yath)

(defun agenda-archive-timestamp (&optional (time (funcall *agenda-now-function*)))
  "Return TIME in GNU Org's minute-precision archive format."
  (multiple-value-bind (second minute hour day month year weekday)
      (decode-universal-time time)
    (declare (ignore second))
    (format nil "~4,'0d-~2,'0d-~2,'0d ~a ~2,'0d:~2,'0d"
            year month day (aref *agenda-weekday-names* weekday) hour minute)))

(defun agenda-default-archive-pathname (source)
  "Return GNU Org's default `%s_archive::' destination for SOURCE."
  (uiop:parse-native-namestring
   (concatenate 'string (uiop:native-namestring source) "_archive")))

(defun agenda-archive-abbreviated-file-name (source)
  "Abbreviate SOURCE below HOME like GNU Emacs `abbreviate-file-name'."
  (let* ((source (uiop:native-namestring source))
         (home (ignore-errors
                 (uiop:native-namestring
                  (uiop:ensure-directory-pathname
                   (truename (user-homedir-pathname)))))))
    (if (and home (alexandria:starts-with-subseq home source))
        (concatenate 'string "~/" (subseq source (length home)))
        source)))

(defun agenda-archive-regexp-group (scanner text)
  "Return SCANNER's first capture in TEXT."
  (multiple-value-bind (start end starts ends) (cl-ppcre:scan scanner text)
    (declare (ignore start end))
    (when (and starts (aref starts 0))
      (subseq text (aref starts 0) (aref ends 0)))))

(defun agenda-archive-file-keyword-values (buffer keyword)
  "Return BUFFER's real Org KEYWORD values in source order."
  (let ((scanner
          (cl-ppcre:create-scanner
           (format nil "(?i)^#\\+~a:\\s*(.*?)\\s*$"
                   (cl-ppcre:quote-meta-chars keyword))))
        (values '())
        (open-block nil))
    (with-point ((point (buffer-start-point buffer)))
      (loop
        (let ((marker (org-block-marker (line-string point))))
          (cond
            (open-block
             (when (and marker (eq (car marker) :end)
                        (string= (cdr marker) open-block))
               (setf open-block nil)))
            ((and marker (eq (car marker) :begin))
             (setf open-block (cdr marker)))
            (t
             (alexandria:when-let
                 ((value
                    (agenda-archive-regexp-group
                     scanner (line-string point))))
               (push value values)))))
        (unless (line-offset point 1) (return))))
    (nreverse values)))

(defun agenda-archive-planning-line-p (line)
  (not (null
        (cl-ppcre:scan
         "(?i)^\\s*(?:CLOSED|SCHEDULED|DEADLINE):" line))))

(defun agenda-archive-property-fields (line)
  "Return an Org drawer property's name and value from LINE."
  (multiple-value-bind (start end starts ends)
      (cl-ppcre:scan "^:([^:[:space:]]+):\\s*(.*?)\\s*$" line)
    (declare (ignore start end))
    (when (and starts (aref starts 0))
      (values (string-upcase
               (subseq line (aref starts 0) (aref ends 0)))
              (subseq line (aref starts 1) (aref ends 1))))))

(defun agenda-archive-heading-property (heading name)
  "Return NAME from HEADING's immediate property drawer."
  (with-point ((point heading))
    (unless (line-offset point 1)
      (return-from agenda-archive-heading-property nil))
    (loop :while (agenda-archive-planning-line-p (line-string point))
          :unless (line-offset point 1)
            :do (return-from agenda-archive-heading-property nil))
    (unless (string-equal ":PROPERTIES:" (line-string point))
      (return-from agenda-archive-heading-property nil))
    (loop :while (line-offset point 1)
          :for line := (line-string point)
          :do (when (string-equal ":END:" line) (return nil))
              (multiple-value-bind (property value)
                  (agenda-archive-property-fields line)
                (when (and property (string-equal property name))
                  (return value))))))

(defun agenda-archive-ancestor-headings (heading)
  "Return HEADING's ancestors from the root down to its parent."
  (loop :with result := '()
        :for current := heading :then parent
        :for parent := (org-parent-heading-point current)
        :while parent
        :do (push parent result)
        :finally (return result)))

(defun agenda-archive-heading-title (heading)
  (multiple-value-bind (level title tags)
      (roam-org-heading-fields (line-string heading))
    (declare (ignore level tags))
    title))

(defun agenda-archive-category (buffer source heading ancestors)
  "Return GNU Org's effective category for HEADING."
  (or (loop :for candidate :in (cons heading (reverse ancestors))
            :for value := (agenda-archive-heading-property candidate "CATEGORY")
            :when (plusp (length value)) :return value)
      (find-if (lambda (value) (plusp (length value)))
               (agenda-archive-file-keyword-values buffer "CATEGORY"))
      (pathname-name source)))

(defun agenda-archive-inherited-tags (buffer heading ancestors)
  "Return inherited tags that are not also local on HEADING."
  (let ((local (agenda-heading-tags (line-string heading)))
        (result '()))
    (labels ((add (tag)
               (unless (or (member tag local :test #'string=)
                           (member tag result :test #'string=))
                 (push tag result))))
      (dolist (value (agenda-archive-file-keyword-values buffer "FILETAGS"))
        (dolist (tag (agenda-normalize-tags value)) (add tag)))
      (dolist (ancestor ancestors)
        (dolist (tag (agenda-heading-tags (line-string ancestor))) (add tag))))
    (nreverse result)))

(defun agenda-archive-custom-location (buffer heading ancestors)
  "Return a file- or subtree-local custom archive location, if present."
  (or (first (agenda-archive-file-keyword-values buffer "ARCHIVE"))
      (loop :for candidate :in (cons heading (reverse ancestors))
            :for value := (agenda-archive-heading-property candidate "ARCHIVE")
            :when (plusp (length value)) :return value)))

(defun agenda-archive-context (buffer source heading)
  "Return GNU Org's default archive context properties for HEADING."
  (let* ((ancestors (agenda-archive-ancestor-headings heading))
         (custom-location
           (agenda-archive-custom-location buffer heading ancestors)))
    (when custom-location
      (error "Custom Org archive location ~s is not supported; source unchanged"
             custom-location))
    (multiple-value-bind (todo-start todo-end todo)
        (org-heading-todo-bounds heading)
      (declare (ignore todo-start todo-end))
      (let ((outline-path
              (format nil "~{~a~^/~}"
                      (mapcar #'agenda-archive-heading-title ancestors)))
            (inherited-tags
              (format nil "~{~a~^ ~}"
                      (agenda-archive-inherited-tags
                       buffer heading ancestors))))
        (remove-if
         (lambda (property) (zerop (length (cdr property))))
         (list
          (cons "TIME" (agenda-archive-timestamp))
          (cons "FILE" (agenda-archive-abbreviated-file-name source))
          (cons "OLPATH" outline-path)
          (cons "CATEGORY"
                (or (agenda-archive-category
                     buffer source heading ancestors)
                    ""))
          (cons "TODO" (or todo ""))
          (cons "ITAGS" inherited-tags)))))))

(defun agenda-archive-split-lines (text)
  "Split TEXT into lines without manufacturing a trailing empty line."
  (let ((start 0)
        (length (length text))
        (lines '()))
    (loop :while (< start length)
          :for newline := (position #\Newline text :start start)
          :do (push (subseq text start (or newline length)) lines)
              (if newline
                  (setf start (1+ newline))
                  (setf start length)))
    (nreverse lines)))

(defun agenda-archive-align-heading-line (line)
  "Align LINE's local tag suffix using the active Org terminal column."
  (let ((tags (agenda-heading-tag-string line)))
    (if (zerop (length tags))
        line
        (let* ((trimmed (string-right-trim '(#\Space #\Tab) line))
               (tag-start (- (length trimmed) (length tags)))
               (prefix (string-right-trim
                        '(#\Space #\Tab) (subseq trimmed 0 tag-start)))
               (target (if (minusp *org-tags-column*)
                           (- (abs *org-tags-column*) (length tags))
                           *org-tags-column*))
               (spaces (max 1 (- target (length prefix)))))
          (concatenate 'string prefix (make-string spaces :initial-element #\Space)
                       tags)))))

(defun agenda-adjust-subtree-level-lines (text old-level new-level)
  "Adjust TEXT's real headings from OLD-LEVEL to NEW-LEVEL."
  (let ((delta (- new-level old-level))
        (open-block nil)
        (result '()))
    (dolist (line (agenda-archive-split-lines text) (nreverse result))
      (let ((marker (org-block-marker line)))
        (cond
          (open-block
           (when (and marker (eq (car marker) :end)
                      (string= (cdr marker) open-block))
             (setf open-block nil))
           (push line result))
          ((and marker (eq (car marker) :begin))
           (setf open-block (cdr marker))
           (push line result))
          ((org-heading-level-from-line line)
           (push (agenda-archive-align-heading-line
                  (cond
                    ((plusp delta)
                     (concatenate 'string
                                  (make-string delta :initial-element #\*) line))
                    ((minusp delta) (subseq line (- delta)))
                    (t line)))
                 result))
          (t (push line result)))))))

(defun agenda-archive-normalize-subtree-lines (text root-level)
  "Normalize TEXT's real headings so its root becomes level one."
  (agenda-adjust-subtree-level-lines text root-level 1))

(defun agenda-archive-property-line-index (lines start end name)
  (loop :for index :from start :below end
        :do (multiple-value-bind (property value)
                (agenda-archive-property-fields (nth index lines))
              (declare (ignore value))
              (when (and property (string-equal property name))
                (return index)))))

(defun agenda-archive-insert-list-at (list index additions)
  (append (subseq list 0 index) additions (nthcdr index list)))

(defun agenda-archive-add-context (lines properties)
  "Add or replace archive PROPERTIES in root entry LINES."
  (let ((drawer-start
          (loop :for index :from 1 :below (length lines)
                :for line := (nth index lines)
                :while (agenda-archive-planning-line-p line)
                :finally (return index))))
    (if (and (< drawer-start (length lines))
             (string-equal ":PROPERTIES:" (nth drawer-start lines)))
        (let ((drawer-end
                (position ":END:" lines :start (1+ drawer-start)
                          :test #'string-equal)))
          (unless drawer-end
            (error "Malformed Org property drawer in archived subtree"))
          (dolist (property properties)
            (let* ((name (car property))
                   (line (format nil ":ARCHIVE_~a: ~a" name (cdr property)))
                   (existing
                     (agenda-archive-property-line-index
                      lines (1+ drawer-start) drawer-end
                      (format nil "ARCHIVE_~a" name))))
              (if existing
                  (setf (nth existing lines) line)
                  (progn
                    (setf lines
                          (agenda-archive-insert-list-at
                           lines drawer-end (list line)))
                    (incf drawer-end)))))
          lines)
        (agenda-archive-insert-list-at
         lines drawer-start
         (append
          (list ":PROPERTIES:")
          (mapcar (lambda (property)
                    (format nil ":ARCHIVE_~a: ~a"
                            (car property) (cdr property)))
                  properties)
          (list ":END:"))))))

(defun agenda-archive-entry-text (subtree root-level properties)
  "Return SUBTREE normalized and annotated for a top-level archive entry."
  (format nil "~{~a~%~}"
          (agenda-archive-add-context
           (agenda-archive-normalize-subtree-lines subtree root-level)
           properties)))

(defun agenda-archive-append-prefix (archive-buffer new-file-p source)
  "Return text separating a new archive entry from ARCHIVE-BUFFER."
  (let ((empty-p
          (= (position-at-point (buffer-start-point archive-buffer))
             (position-at-point (buffer-end-point archive-buffer)))))
    (cond
      ((and new-file-p empty-p)
       (format nil
               "#    -*- mode: org -*-~%~%~%Archived entries from file ~a~%~%~%"
               (uiop:native-namestring source)))
      (empty-p (format nil "#    -*- mode: org -*-~%~%~%"))
      (t (string #\Newline)))))

(defun agenda-archive-append-and-save (archive source entry)
  "Append ENTRY to ARCHIVE and save it before the source is changed."
  (let* ((new-file-p (null (probe-file archive)))
         (buffer (find-file-buffer archive))
         (original-modified-p (buffer-modified-p buffer))
         (start (copy-point (buffer-end-point buffer) :right-inserting))
         (insertion (copy-point start :temporary)))
    (when (buffer-read-only-p buffer)
      (error "Archive destination is read-only: ~a" archive))
    (handler-case
        (progn
          (insert-string insertion
                         (concatenate
                          'string
                          (agenda-archive-append-prefix
                           buffer new-file-p source)
                          entry))
          (save-buffer buffer)
          buffer)
      (error (condition)
        (delete-between-points start (buffer-end-point buffer))
        (unless original-modified-p (buffer-mark-saved buffer))
        (error condition)))))

(defun agenda-archive-delete-source-and-save
    (buffer heading end subtree original-modified-p archive)
  "Delete HEADING..END and save BUFFER, restoring it if the save fails."
  (delete-between-points heading end)
  (handler-case
      (save-buffer buffer)
    (error (condition)
      (insert-string heading subtree)
      (unless original-modified-p (buffer-mark-saved buffer))
      (error "Archive destination ~a was saved, but source removal failed: ~a"
             archive condition))))

(defun agenda-archive-source-subtree (file line expected-heading)
  "Archive one exact agenda subtree and save destination then source.

Return the archive pathname and the source line immediately after the moved
subtree, or NIL as the latter value when the subtree reached end of file."
  (unless (and file (integerp line) (plusp line) expected-heading)
    (error "No mutable agenda heading on this line"))
  (let ((source-buffer (find-file-buffer file)))
    (with-current-buffer source-buffer
      (when (buffer-read-only-p source-buffer)
        (error "Agenda source is read-only: ~a" file))
      (with-point ((heading (buffer-start-point source-buffer)))
        (unless (or (= line 1) (line-offset heading (1- line)))
          (error "Agenda source line no longer exists; refresh the agenda"))
        (unless (string= expected-heading (line-string heading))
          (error "Agenda source changed; refresh before archiving"))
        (let* ((root-level (org-heading-level-at heading))
               (end (and root-level (org-subtree-end-point heading))))
          (unless (and root-level end)
            (error "Agenda row no longer names an Org subtree"))
          (let* ((source (or (ignore-errors (truename file)) file))
                 (archive (agenda-default-archive-pathname source))
                 (subtree (points-to-string heading end))
                 (properties
                   (agenda-archive-context source-buffer source heading))
                 (entry
                   (agenda-archive-entry-text subtree root-level properties))
                 (end-line
                   (unless (end-buffer-p end) (line-number-at-point end)))
                 (original-modified-p
                   (buffer-modified-p source-buffer)))
            (agenda-archive-append-and-save archive source entry)
            (agenda-archive-delete-source-and-save
             source-buffer heading end subtree original-modified-p archive)
            (values archive end-line)))))))

(defun agenda-archive-row-in-subtree-p (point file start-line end-line)
  (let ((row-file (text-property-at point :agenda-file))
        (row-line (text-property-at point :agenda-line)))
    (and row-file row-line
         (uiop:pathname-equal row-file file)
         (>= row-line start-line)
         (or (null end-line) (< row-line end-line)))))

(defun agenda-archive-neighbor-key (origin file start-line end-line)
  "Return the nearest rendered row outside the subtree being archived."
  (labels ((scan (direction)
             (with-point ((point origin))
               (loop :while (line-offset point direction)
                     :for key := (agenda-entry-key-at-point point)
                     :when (and key
                                (not (agenda-archive-row-in-subtree-p
                                      point file start-line end-line)))
                       :return key))))
    (or (scan 1) (scan -1))))

(defun agenda-archive-current-entry (&optional confirm-p)
  "Archive the agenda subtree at point, optionally asking for confirmation."
  (let* ((agenda-buffer (current-buffer))
         (origin (copy-point (current-point) :temporary))
         (file (text-property-at origin :agenda-file))
         (line (text-property-at origin :agenda-line))
         (heading (text-property-at origin :agenda-heading)))
    (cond
      ((null file)
       (message "No agenda entry on this line."))
      ((and confirm-p
            (not (prompt-for-y-or-n-p "Archive this subtree or entry?")))
       (message "Archive cancelled"))
      (t
       (handler-case
           (multiple-value-bind (archive end-line)
               (agenda-archive-source-subtree file line heading)
             (setf (buffer-value agenda-buffer
                                 'lem-yath-agenda-restore-entry)
                   (agenda-archive-neighbor-key
                    origin file line end-line))
             (agenda-start-scan agenda-buffer)
             (message "Subtree archived in file: ~a"
                      (uiop:native-namestring archive)))
         (error (condition)
           (message "Agenda archive failed: ~a" condition)))))))

(define-command lem-yath-agenda-archive () ()
  "Archive and persist the current agenda subtree without confirmation."
  (agenda-archive-current-entry))

(define-command lem-yath-agenda-archive-with-confirmation () ()
  "Confirm, then archive and persist the current agenda subtree."
  (agenda-archive-current-entry t))

;; Evil-Org's agenda bindings.
(define-key *lem-yath-agenda-vi-keymap* "d A" 'lem-yath-agenda-archive)
(define-key *lem-yath-agenda-vi-keymap* "d a"
  'lem-yath-agenda-archive-with-confirmation)

;; GNU Org agenda bindings retained underneath Evil-Org.
(dolist (keys '("$" "C-c $" "C-c C-x C-s" "C-c C-x C-a"))
  (define-key *lem-yath-agenda-vi-keymap* keys 'lem-yath-agenda-archive)
  (define-key *lem-yath-agenda-mode-keymap* keys 'lem-yath-agenda-archive))

(define-key *lem-yath-agenda-mode-keymap* "d A" 'lem-yath-agenda-archive)
(define-key *lem-yath-agenda-mode-keymap* "d a"
  'lem-yath-agenda-archive-with-confirmation)
