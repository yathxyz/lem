;;;; Ibuffer-style saved filter groups on Lem's native buffer chooser.

(in-package :lem-yath)

(defparameter *buffer-list-filter-groups*
  '(("org" . buffer-list-org-buffer-p)
    ("tramp" . buffer-list-tramp-buffer-p)
    ("emacs" . buffer-list-emacs-buffer-p)
    ("ediff" . buffer-list-ediff-buffer-p)
    ("dired" . buffer-list-dired-buffer-p)
    ("terminal" . buffer-list-terminal-buffer-p)
    ("help" . buffer-list-help-buffer-p))
  "The effective Emacs Ibuffer groups, in their configured first-match order.")

(defun buffer-list-name-prefix-p (prefix buffer)
  (let ((name (buffer-name buffer)))
    (and (<= (length prefix) (length name))
         (string= prefix name :end2 (length prefix)))))

(defun buffer-list-name-equal-p (name buffer)
  (string= name (buffer-name buffer)))

(defun buffer-list-mode-named-p (buffer names)
  (member (symbol-name (buffer-major-mode buffer)) names :test #'string=))

(defun buffer-list-minor-mode-named-p (buffer names)
  (some (lambda (mode)
          (member (symbol-name mode) names :test #'string=))
        (buffer-minor-modes buffer)))

(defun buffer-list-org-buffer-p (buffer)
  (or (buffer-list-mode-named-p buffer '("ORG-MODE"))
      (buffer-list-name-prefix-p "*Org Src" buffer)
      (buffer-list-name-equal-p "*Org Agenda*" buffer)
      ;; Lem's native equivalent deliberately has a shorter buffer name.
      (buffer-list-name-equal-p "*Agenda*" buffer)
      (buffer-list-mode-named-p buffer '("LEM-YATH-AGENDA-MODE"))))

(defun buffer-list-tramp-buffer-p (buffer)
  (buffer-list-name-prefix-p "*tramp" buffer))

(defun buffer-list-emacs-buffer-p (buffer)
  (member (buffer-name buffer)
          '("*scratch*" "*Messages*" "*Warnings*")
          :test #'string=))

(defun buffer-list-ediff-buffer-p (buffer)
  (or (buffer-list-name-prefix-p "*ediff" buffer)
      (buffer-list-name-prefix-p "*Ediff" buffer)))

(defun buffer-list-dired-buffer-p (buffer)
  (buffer-list-mode-named-p buffer '("DIRECTORY-MODE" "FILER-MODE")))

(defun buffer-list-terminal-buffer-p (buffer)
  (or (buffer-list-mode-named-p
       buffer '("TERM-MODE" "SHELL-MODE" "ESHELL-MODE" "RUN-SHELL-MODE"))
      (buffer-list-minor-mode-named-p buffer '("LISTENER-MODE"))))

(defun buffer-list-help-buffer-p (buffer)
  (member (buffer-name buffer) '("*Help*" "*info*") :test #'string=))

(defun buffer-list-group-name (buffer)
  "Return BUFFER's first configured group, or \"Default\"."
  (or (loop :for (name . predicate) :in *buffer-list-filter-groups*
            :when (funcall predicate buffer)
              :return name)
      "Default"))

(defun make-buffer-list-entry (group buffer)
  (list group nil buffer))

(defun make-buffer-list-heading (group)
  (list group :heading nil))

(defun buffer-list-entry-group (entry)
  (first entry))

(defun buffer-list-entry-heading-p (entry)
  (eq :heading (second entry)))

(defun buffer-list-entry-buffer (entry)
  (third entry))

(defun buffer-list-partition (buffers predicate)
  "Partition BUFFERS by PREDICATE, preserving order in both values."
  (let (matching remaining)
    (dolist (buffer buffers)
      (if (funcall predicate buffer)
          (push buffer matching)
          (push buffer remaining)))
    (values (nreverse matching) (nreverse remaining))))

(defun buffer-list-grouped-entries (&optional (buffers (buffer-list)))
  "Group BUFFERS like the configured Ibuffer view, omitting empty groups.

Each nonempty group begins with a distinct heading entry."
  (let ((remaining (copy-list buffers))
        entries)
    (dolist (group *buffer-list-filter-groups*)
      (multiple-value-bind (matching rest)
          (buffer-list-partition remaining (cdr group))
        (setf remaining rest)
        (when matching
          (push (make-buffer-list-heading (car group)) entries)
          (loop :for buffer :in matching
                :do (push (make-buffer-list-entry
                           (car group) buffer)
                          entries)))))
    (when remaining
      (push (make-buffer-list-heading "Default") entries)
      (loop :for buffer :in remaining
            :do (push (make-buffer-list-entry "Default" buffer)
                      entries)))
    (nreverse entries)))

(defclass buffer-list-component (lem/multi-column-list:multi-column-list)
  ((all-items
    :initform nil
    :accessor buffer-list-component-all-items)
   (hidden-groups
    :initform nil
    :accessor buffer-list-component-hidden-groups)
   (sort-mode
    :initform :recency
    :accessor buffer-list-component-sort-mode)
   (sort-reversed-p
    :initform nil
    :accessor buffer-list-component-sort-reversed-p)
   (format-index
    :initform 0
    :accessor buffer-list-component-format-index)
   (recency-ranks
    :initform (make-hash-table :test #'eq)
    :reader buffer-list-component-recency-ranks)
   (deletion-items
    :initform (make-hash-table :test #'eq)
    :reader buffer-list-component-deletion-items)
   (filters
    :initform nil
    :accessor buffer-list-component-filters)
   (pending-filter-kind
    :initform nil
    :accessor buffer-list-component-pending-filter-kind)))

(defparameter *buffer-list-sort-mode-cycle*
  '(:alphabetic :filename :major-mode :mode-name :recency :size)
  "The lexical cycle used by pinned Ibuffer's comma command.")

(defun buffer-list-format-columns (component)
  (ecase (buffer-list-component-format-index component)
    (0 '("" "Buffer" "Size" "Mode" "File"))
    (1 '("Buffer" "File"))))

(defmethod lem/multi-column-list::multi-column-list-columns
    ((component buffer-list-component))
  (buffer-list-format-columns component))

(define-minor-mode buffer-list-picker-mode
    (:name "buffer-list-picker"
     :keymap *buffer-list-picker-mode-keymap*
     :hide-from-modeline t))

(defvar *buffer-list-filter-input-mode-keymap*
  (make-keymap :description '*buffer-list-filter-input-mode-keymap*)
  "Literal input map used while entering an Ibuffer regexp filter.")

(define-minor-mode buffer-list-filter-input-mode
    (:name "buffer-list-filter-input"
     :keymap *buffer-list-filter-input-mode-keymap*
     :hide-from-modeline t))

(defmethod initialize-instance :after
    ((component buffer-list-component) &key &allow-other-keys)
  (let ((items
          (copy-list
           (lem/multi-column-list::multi-column-list-items component))))
    (setf (buffer-list-component-all-items component) items)
    (loop :with rank := 0
          :for item :in items
          :for entry := (buffer-list-item-entry item)
          :unless (buffer-list-entry-heading-p entry)
            :do (setf (gethash (buffer-list-entry-buffer entry)
                               (buffer-list-component-recency-ranks component))
                      rank)
                (incf rank))))

(defun buffer-list-item-entry (item)
  (lem/multi-column-list::unwrap item))

(defun buffer-list-item-mark-string (component item)
  (let ((entry (buffer-list-item-entry item)))
    (cond
      ((buffer-list-entry-heading-p entry) "  ")
      ((gethash item (buffer-list-component-deletion-items component)) "D ")
      ((lem/multi-column-list::multi-column-list-item-checked-p item) "> ")
      (t "  "))))

(defmethod lem/multi-column-list:map-columns :around
    ((component buffer-list-component) item)
  (let ((columns (call-next-method)))
    (if (lem/multi-column-list::multi-column-list-use-check-p component)
        (cons (buffer-list-item-mark-string component item) (rest columns))
        columns)))

(defun buffer-list-component-entries (component)
  (mapcar #'buffer-list-item-entry
          (buffer-list-component-all-items component)))

(defun buffer-list-group-hidden-p (component group)
  (member group
          (buffer-list-component-hidden-groups component)
          :test #'string=))

(defun buffer-list-regexp-match-p (pattern value)
  (and value
       (handler-case
           (not (null (cl-ppcre:scan
                       (cl-ppcre:create-scanner
                        pattern :case-insensitive-mode t)
                       value)))
         (error () nil))))

(defun buffer-list-filter-match-p (filter buffer)
  (ecase (first filter)
    (:modified (buffer-modified-p buffer))
    (:visiting-file (buffer-filename buffer))
    (:mode
     (buffer-list-regexp-match-p
      (second filter) (symbol-name (buffer-major-mode buffer))))
    (:name
     (buffer-list-regexp-match-p (second filter) (buffer-name buffer)))
    (:filename
     (buffer-list-regexp-match-p (second filter) (buffer-filename buffer)))
    (:basename
     (alexandria:when-let ((filename (buffer-filename buffer)))
       (buffer-list-regexp-match-p
        (second filter) (file-namestring filename))))
    (:extension
     (alexandria:when-let ((filename (buffer-filename buffer)))
       (buffer-list-regexp-match-p
        (second filter) (or (pathname-type filename) ""))))
    (:not (not (buffer-list-filter-match-p (second filter) buffer)))))

(defun buffer-list-active-filters-match-p (component buffer)
  (every (lambda (filter) (buffer-list-filter-match-p filter buffer))
         (buffer-list-component-filters component)))

(defun buffer-list-reset-visible-items (component)
  "Rebuild grouped rows after active filters or collapsed groups change."
  (let ((remaining (copy-list (buffer-list-component-all-items component)))
        result)
    (loop :while remaining
          :for heading := (pop remaining)
          :for heading-entry := (buffer-list-item-entry heading)
          :for members :=
            (loop :while (and remaining
                              (not (buffer-list-entry-heading-p
                                    (buffer-list-item-entry
                                     (first remaining)))))
                  :collect (pop remaining))
          :for matching :=
            (remove-if-not
             (lambda (item)
               (buffer-list-active-filters-match-p
                component
                (buffer-list-entry-buffer (buffer-list-item-entry item))))
             members)
          :do
             (unless (buffer-list-entry-heading-p heading-entry)
               (error "Buffer-list group is missing its heading"))
             (when matching
               (push heading result)
               (unless (buffer-list-group-hidden-p
                        component (buffer-list-entry-group heading-entry))
                 (dolist (item matching)
                   (push item result)))))
    (setf (lem/multi-column-list::multi-column-list-items component)
          (nreverse result))))

(defun buffer-list-filter-entries (component query)
  "Filter COMPONENT's entries through the established buffer matcher."
  (let* ((entries (buffer-list-component-entries component))
         (buffer-entries
           (remove-if-not
            (lambda (entry)
              (and (not (buffer-list-entry-heading-p entry))
                   (buffer-list-active-filters-match-p
                    component (buffer-list-entry-buffer entry))))
            entries))
         matching)
    (let ((by-buffer (make-hash-table :test #'eq)))
      (dolist (entry buffer-entries)
        (setf (gethash (buffer-list-entry-buffer entry) by-buffer) entry))
      (if (buffer-list-component-pending-filter-kind component)
          (dolist (entry buffer-entries)
            (let ((buffer (buffer-list-entry-buffer entry)))
              (when (buffer-list-filter-match-p
                     (list (buffer-list-component-pending-filter-kind component)
                           query)
                     buffer)
                (setf (gethash buffer by-buffer) :matching))))
          (dolist (buffer
                   (completion-buffer
                    query (mapcar #'buffer-list-entry-buffer buffer-entries)))
            (when (gethash buffer by-buffer)
              (setf (gethash buffer by-buffer) :matching))))
      ;; Manual Ibuffer sorting remains authoritative while narrowing.  The
      ;; completion matcher decides membership, but does not reorder matches.
      (dolist (entry buffer-entries)
        (when (eq :matching
                  (gethash (buffer-list-entry-buffer entry) by-buffer))
          (push entry matching))))
    ;; Live filtering is a selection view rather than an Ibuffer group view:
    ;; omit headings so Return keeps selecting the first matching buffer.  A
    ;; collapsed group becomes visible to a direct query and is restored when
    ;; the query is cleared.
    (nreverse matching)))

(defun buffer-list-sort-string (buffer mode)
  (ecase mode
    (:alphabetic (buffer-name buffer))
    (:filename (or (buffer-filename buffer) ""))
    (:major-mode
     (string-downcase (symbol-name (buffer-major-mode buffer))))
    (:mode-name
     (string-downcase (mode-name (buffer-major-mode buffer))))))

(defun buffer-list-item-less-p (component left right mode)
  (let ((left-buffer
          (buffer-list-entry-buffer (buffer-list-item-entry left)))
        (right-buffer
          (buffer-list-entry-buffer (buffer-list-item-entry right))))
    (ecase mode
      ((:alphabetic :filename :major-mode :mode-name)
       (string< (buffer-list-sort-string left-buffer mode)
                (buffer-list-sort-string right-buffer mode)))
      (:size
       (< (completion-buffer-size left-buffer)
          (completion-buffer-size right-buffer)))
      (:recency
       (< (gethash left-buffer
                   (buffer-list-component-recency-ranks component)
                   most-positive-fixnum)
          (gethash right-buffer
                   (buffer-list-component-recency-ranks component)
                   most-positive-fixnum))))))

(defun buffer-list-sort-all-items (component)
  "Sort buffers inside each configured group without moving headings."
  (let ((remaining (copy-list (buffer-list-component-all-items component)))
        result)
    (loop :while remaining
          :for heading := (pop remaining)
          :for entry := (buffer-list-item-entry heading)
          :do
             (unless (buffer-list-entry-heading-p entry)
               (error "Buffer-list group is missing its heading"))
             (push heading result)
             (let (members)
               (loop :while (and remaining
                                 (not (buffer-list-entry-heading-p
                                       (buffer-list-item-entry
                                        (first remaining)))))
                     :do (push (pop remaining) members))
               (setf members
                     (stable-sort
                      (nreverse members)
                      (lambda (left right)
                        (buffer-list-item-less-p
                         component left right
                         (buffer-list-component-sort-mode component)))))
               (when (buffer-list-component-sort-reversed-p component)
                 (setf members (nreverse members)))
               (dolist (member members)
                 (push member result))))
    (setf (buffer-list-component-all-items component) (nreverse result))))

(defun buffer-list-refresh (component &key recompute-columns)
  (buffer-list-reset-visible-items component)
  (when recompute-columns
    (setf (lem/multi-column-list::multi-column-list-print-spec component)
          (make-instance
           'lem/multi-column-list::print-spec
           :multi-column-list component
           :column-width-list
           (lem/multi-column-list::compute-column-width-list component))))
  (lem/multi-column-list:update component))

(defun buffer-list-sort-description (mode)
  (ecase mode
    (:alphabetic "buffer name")
    (:filename "file name")
    (:major-mode "major mode")
    (:mode-name "major mode name")
    (:recency "recency")
    (:size "size")))

(defun buffer-list-set-sort-mode (component mode)
  (setf (buffer-list-component-sort-mode component) mode)
  (buffer-list-sort-all-items component)
  (buffer-list-refresh component)
  (message "Sorting by ~a~:[~; (reversed)~]"
           (buffer-list-sort-description mode)
           (buffer-list-component-sort-reversed-p component)))

(defun buffer-list-attributes (buffer)
  "Return Ibuffer's modified, read-only, and reserved lock status fields."
  (format nil "~c~c "
          (if (buffer-modified-p buffer) #\* #\Space)
          (if (buffer-read-only-p buffer) #\% #\Space)))

(defun buffer-list-fixed-field (value width)
  "Fit VALUE to exactly WIDTH terminal cells using Ibuffer-style elision."
  (let ((display-width (lem/common/character:string-width value)))
    (cond
      ((< display-width width)
       (concatenate 'string value
                    (make-string (- width display-width)
                                 :initial-element #\Space)))
      ((= display-width width) value)
      (t
       (let* ((ellipsis "...")
              (prefix-width (- width
                               (lem/common/character:string-width ellipsis)))
              (end (or (lem/common/character:wide-index value prefix-width)
                       (length value)))
              (prefix (subseq value 0 end))
              (padding (- prefix-width
                          (lem/common/character:string-width prefix))))
         (concatenate 'string prefix
                      (make-string padding :initial-element #\.)
                      ellipsis))))))

(defun buffer-list-primary-columns (component entry)
  (if (buffer-list-entry-heading-p entry)
      (list ""
            (format nil "[ ~a~a ]"
                    (buffer-list-entry-group entry)
                    (if (buffer-list-group-hidden-p
                         component (buffer-list-entry-group entry))
                        " ..."
                        ""))
            ""
            ""
            "")
      (let ((buffer (buffer-list-entry-buffer entry)))
        (list (buffer-list-attributes buffer)
              (buffer-list-fixed-field
               (completion-path-display-string (buffer-name buffer)) 18)
              (format nil "~9d" (completion-buffer-size buffer))
              (buffer-list-fixed-field
               (mode-name (buffer-major-mode buffer)) 16)
              (if (buffer-filename buffer)
                  (completion-path-display-string (buffer-filename buffer))
                  "")))))

(defun buffer-list-compact-columns (component entry)
  (if (buffer-list-entry-heading-p entry)
      (list
       (format nil "[ ~a~a ]"
               (buffer-list-entry-group entry)
               (if (buffer-list-group-hidden-p
                    component (buffer-list-entry-group entry))
                   " ..."
                   ""))
       "")
      (let ((buffer (buffer-list-entry-buffer entry)))
        (list
         (completion-path-display-string (buffer-name buffer))
         (if (buffer-filename buffer)
             (completion-path-display-string (buffer-filename buffer))
             "")))))

(defun buffer-list-columns (component entry)
  (ecase (buffer-list-component-format-index component)
    (0 (buffer-list-primary-columns component entry))
    (1 (buffer-list-compact-columns component entry))))

(defun buffer-list-toggle-group (component group)
  (if (buffer-list-group-hidden-p component group)
      (setf (buffer-list-component-hidden-groups component)
            (delete group
                    (buffer-list-component-hidden-groups component)
                    :test #'string=))
      (push group (buffer-list-component-hidden-groups component)))
  (buffer-list-reset-visible-items component)
  (lem/multi-column-list:update component))

(defun buffer-list-select (component entry)
  (if (buffer-list-entry-heading-p entry)
      (buffer-list-toggle-group component (buffer-list-entry-group entry))
      (progn
        (lem/multi-column-list:quit component)
        (switch-to-buffer (buffer-list-entry-buffer entry)))))

(defun buffer-list-delete (component entry)
  (declare (ignore component))
  (kill-buffer (buffer-list-entry-buffer entry)))

(defun buffer-list-save (component entry)
  (declare (ignore component))
  (unless (buffer-list-entry-heading-p entry)
    (save-buffer (buffer-list-entry-buffer entry))))

(defun buffer-list-current-item (component)
  (lem/multi-column-list::current-focus-item component))

(defun buffer-list-current-entry (component)
  (alexandria:when-let ((item (buffer-list-current-item component)))
    (buffer-list-item-entry item)))

(defun buffer-list-set-item-mark (component item mark)
  (let ((entry (and item (buffer-list-item-entry item))))
    (when (and entry (not (buffer-list-entry-heading-p entry)))
      (ecase mark
        (:none
         (setf (lem/multi-column-list::multi-column-list-item-checked-p item)
               nil)
         (remhash item (buffer-list-component-deletion-items component)))
        (:marked
         (setf (lem/multi-column-list::multi-column-list-item-checked-p item)
               t)
         (remhash item (buffer-list-component-deletion-items component)))
        (:deletion
         (setf (lem/multi-column-list::multi-column-list-item-checked-p item)
               t
               (gethash item
                        (buffer-list-component-deletion-items component))
               t)))
      t)))

(defun buffer-list-toggle-current-check (component)
  (alexandria:when-let ((entry (buffer-list-current-entry component)))
    (unless (buffer-list-entry-heading-p entry)
      (let ((item (buffer-list-current-item component)))
        (buffer-list-set-item-mark
         component item
         (if (lem/multi-column-list::multi-column-list-item-checked-p item)
             :none
             :marked))
        (lem/multi-column-list:update component)))))

(defun buffer-list-mark-current-and-down (component mark)
  (when (buffer-list-set-item-mark
         component (buffer-list-current-item component) mark)
    (lem/multi-column-list:update component))
  (lem/multi-column-list::multi-column-list/down))

(defun buffer-list-unmark-all (component)
  (dolist (item (buffer-list-component-all-items component))
    (buffer-list-set-item-mark component item :none))
  (clrhash (buffer-list-component-deletion-items component))
  (lem/multi-column-list:update component))

(defun buffer-list-current-view-items (component)
  (if (plusp
       (length
        (lem/multi-column-list::multi-column-list-search-string component)))
      (lem/multi-column-list::filtered-items component)
      (lem/multi-column-list::multi-column-list-items component)))

(defun buffer-list-toggle-all-marks (component)
  (dolist (item (buffer-list-current-view-items component))
    (let ((entry (buffer-list-item-entry item)))
      (unless (buffer-list-entry-heading-p entry)
        (buffer-list-set-item-mark
         component item
         (if (lem/multi-column-list::multi-column-list-item-checked-p item)
             :none
             :marked)))))
  (lem/multi-column-list:update component))

(define-command lem-yath-buffer-list-check-and-down () ()
  (let ((component (lem/multi-column-list::current-multi-column-list)))
    (buffer-list-toggle-current-check component)
    (lem/multi-column-list::multi-column-list/down)))

(define-command lem-yath-buffer-list-up-and-check () ()
  (let ((component (lem/multi-column-list::current-multi-column-list)))
    (lem/multi-column-list::multi-column-list/up)
    (buffer-list-toggle-current-check component)))

(define-command lem-yath-buffer-list-mark-forward () ()
  (buffer-list-mark-current-and-down
   (lem/multi-column-list::current-multi-column-list) :marked))

(define-command lem-yath-buffer-list-unmark-forward () ()
  (buffer-list-mark-current-and-down
   (lem/multi-column-list::current-multi-column-list) :none))

(define-command lem-yath-buffer-list-mark-deletion () ()
  (buffer-list-mark-current-and-down
   (lem/multi-column-list::current-multi-column-list) :deletion))

(define-command lem-yath-buffer-list-unmark-all () ()
  (buffer-list-unmark-all
   (lem/multi-column-list::current-multi-column-list)))

(define-command lem-yath-buffer-list-toggle-marks () ()
  (buffer-list-toggle-all-marks
   (lem/multi-column-list::current-multi-column-list)))

(defun buffer-list-start-input-filter (kind description)
  (let ((component (lem/multi-column-list::current-multi-column-list)))
    (setf (buffer-list-component-pending-filter-kind component) kind
          (lem/multi-column-list::multi-column-list-search-string component) "")
    (lem/multi-column-list:update component)
    (buffer-list-filter-input-mode t)
    (message "Ibuffer ~a filter (Return accepts, Escape cancels)" description)))

(define-command lem-yath-buffer-list-start-name-filter () ()
  (buffer-list-start-input-filter :name "buffer name"))

(define-command lem-yath-buffer-list-start-mode-filter () ()
  (buffer-list-start-input-filter :mode "major mode in use"))

(define-command lem-yath-buffer-list-start-filename-filter () ()
  (buffer-list-start-input-filter :filename "full file name"))

(define-command lem-yath-buffer-list-start-basename-filter () ()
  (buffer-list-start-input-filter :basename "file basename"))

(define-command lem-yath-buffer-list-start-extension-filter () ()
  (buffer-list-start-input-filter :extension "filename extension"))

(define-command lem-yath-buffer-list-accept-input-filter () ()
  "Commit the pending input filter and return to modal buffer-list commands."
  (let* ((component (lem/multi-column-list::current-multi-column-list))
         (kind (buffer-list-component-pending-filter-kind component))
         (query (lem/multi-column-list::multi-column-list-search-string
                 component)))
    (buffer-list-filter-input-mode nil)
    (setf (buffer-list-component-pending-filter-kind component) nil)
    (when (and kind (plusp (length query)))
      (buffer-list-push-filter component (list kind query)))))

(define-command lem-yath-buffer-list-cancel-input-filter () ()
  "Clear the pending input filter and return to modal buffer-list commands."
  (let ((component (lem/multi-column-list::current-multi-column-list)))
    (setf (buffer-list-component-pending-filter-kind component) nil
          (lem/multi-column-list::multi-column-list-search-string component) "")
    (buffer-list-filter-input-mode nil)
    (lem/multi-column-list:update component)))

(defun buffer-list-filter-description (filter)
  (ecase (first filter)
    (:modified "modified")
    (:visiting-file "visiting-file")
    (:mode (format nil "mode=~a" (second filter)))
    (:name (format nil "name=~a" (second filter)))
    (:filename (format nil "filename=~a" (second filter)))
    (:basename (format nil "basename=~a" (second filter)))
    (:extension (format nil "extension=~a" (second filter)))
    (:not (format nil "not(~a)"
                  (buffer-list-filter-description (second filter))))))

(defun buffer-list-move-focus-off-heading (component)
  (alexandria:when-let ((entry (buffer-list-current-entry component)))
    (when (buffer-list-entry-heading-p entry)
      (lem/multi-column-list::multi-column-list/down))))

(defun buffer-list-refresh-filters (component)
  (setf (lem/multi-column-list::multi-column-list-search-string component) "")
  (buffer-list-reset-visible-items component)
  (lem/multi-column-list:update component)
  (buffer-list-move-focus-off-heading component)
  (let ((descriptions
          (mapcar #'buffer-list-filter-description
                  (buffer-list-component-filters component))))
    (message "Ibuffer filters: ~a"
             (if descriptions
                 (format nil "~{~a~^ + ~}" descriptions)
                 "none"))))

(defun buffer-list-push-filter (component filter)
  (unless (member filter (buffer-list-component-filters component) :test #'equal)
    (push filter (buffer-list-component-filters component)))
  (buffer-list-refresh-filters component))

(define-command lem-yath-buffer-list-filter-modified () ()
  (buffer-list-push-filter
   (lem/multi-column-list::current-multi-column-list) '(:modified)))

(define-command lem-yath-buffer-list-filter-visiting-file () ()
  (buffer-list-push-filter
   (lem/multi-column-list::current-multi-column-list) '(:visiting-file)))

(define-command lem-yath-buffer-list-pop-filter () ()
  (let ((component (lem/multi-column-list::current-multi-column-list)))
    (if (buffer-list-component-filters component)
        (progn
          (pop (buffer-list-component-filters component))
          (buffer-list-refresh-filters component))
        (message "No Ibuffer filters in effect"))))

(define-command lem-yath-buffer-list-negate-filter () ()
  (let ((component (lem/multi-column-list::current-multi-column-list)))
    (if (buffer-list-component-filters component)
        (let ((filter (pop (buffer-list-component-filters component))))
          (push (if (eq :not (first filter))
                    (second filter)
                    (list :not filter))
                (buffer-list-component-filters component))
          (buffer-list-refresh-filters component))
        (message "No Ibuffer filters in effect"))))

(define-command lem-yath-buffer-list-disable-filters () ()
  (let ((component (lem/multi-column-list::current-multi-column-list)))
    (setf (buffer-list-component-filters component) nil)
    (buffer-list-refresh-filters component)))

(defun buffer-list-action-items (component)
  (or (remove-if
       (lambda (item)
         (or (not (lem/multi-column-list::multi-column-list-item-checked-p
                   item))
             (buffer-list-entry-heading-p (buffer-list-item-entry item))))
       (lem/multi-column-list::multi-column-list-items component))
      (alexandria:when-let ((item (buffer-list-current-item component)))
        (unless (buffer-list-entry-heading-p (buffer-list-item-entry item))
          (list item)))))

(defun buffer-list-prune-empty-groups (component)
  (let* ((items (buffer-list-component-all-items component))
         (live-groups
           (loop :for item :in items
                 :for entry := (buffer-list-item-entry item)
                 :unless (buffer-list-entry-heading-p entry)
                   :collect (buffer-list-entry-group entry))))
    (setf (buffer-list-component-all-items component)
          (remove-if
           (lambda (item)
             (let ((entry (buffer-list-item-entry item)))
               (and (buffer-list-entry-heading-p entry)
                    (not (member (buffer-list-entry-group entry)
                                 live-groups :test #'string=)))))
           items))))

(defun buffer-list-delete-items-now (component items)
  (dolist (item items)
    (let ((entry (buffer-list-item-entry item)))
      (buffer-list-delete component entry)
      (remhash item (buffer-list-component-deletion-items component))
      (setf (buffer-list-component-all-items component)
            (delete item
                    (buffer-list-component-all-items component)
                    :test #'eq))))
  (when items
    (buffer-list-prune-empty-groups component)
    (buffer-list-reset-visible-items component)
    (lem/multi-column-list:update component)))

(defun buffer-list-delete-action-items (component)
  (buffer-list-delete-items-now
   component (buffer-list-action-items component)))

(defun buffer-list-deletion-action-items (component)
  (remove-if-not
   (lambda (item)
     (gethash item (buffer-list-component-deletion-items component)))
   (buffer-list-component-all-items component)))

(defun buffer-list-save-action-items (component)
  (let ((items (buffer-list-action-items component)))
    (dolist (item items)
      (buffer-list-save component (buffer-list-item-entry item)))
    (lem/multi-column-list:update component)
    (when items
      (buffer-list-move-focus-off-heading component))))

(defun buffer-list-current-buffer (component)
  (alexandria:when-let ((entry (buffer-list-current-entry component)))
    (unless (buffer-list-entry-heading-p entry)
      (buffer-list-entry-buffer entry))))

(defun buffer-list-require-current-buffer (component)
  (or (buffer-list-current-buffer component)
      (editor-error "No buffer on this Ibuffer row")))

(defun buffer-list-copy-current (value description)
  (copy-to-clipboard-with-killring value)
  (message "Copied ~a: ~a" description value))

(define-command lem-yath-buffer-list-copy-buffer-name () ()
  (let* ((component (lem/multi-column-list::current-multi-column-list))
         (buffer (buffer-list-require-current-buffer component)))
    (buffer-list-copy-current (buffer-name buffer) "buffer name")))

(define-command lem-yath-buffer-list-copy-file-name () ()
  (let* ((component (lem/multi-column-list::current-multi-column-list))
         (buffer (buffer-list-require-current-buffer component))
         (filename (buffer-filename buffer)))
    (unless filename
      (editor-error "Buffer is not visiting a file"))
    (buffer-list-copy-current (namestring filename) "file name")))

(define-command lem-yath-buffer-list-visit-other-window () ()
  (let* ((component (lem/multi-column-list::current-multi-column-list))
         (buffer (buffer-list-require-current-buffer component)))
    (lem/multi-column-list:quit component)
    (switch-to-window (pop-to-buffer buffer))))

(defun buffer-list-record-marks (component)
  (let ((marks (make-hash-table :test #'eq)))
    (dolist (item (buffer-list-component-all-items component) marks)
      (let ((entry (buffer-list-item-entry item)))
        (unless (buffer-list-entry-heading-p entry)
          (cond
            ((gethash item (buffer-list-component-deletion-items component))
             (setf (gethash (buffer-list-entry-buffer entry) marks) :deletion))
            ((lem/multi-column-list::multi-column-list-item-checked-p item)
             (setf (gethash (buffer-list-entry-buffer entry) marks) :marked))))))))

(defun buffer-list-focus-buffer (component buffer)
  (when buffer
    (alexandria:when-let
        ((index
           (position buffer
                     (lem/multi-column-list::multi-column-list-items component)
                     :key (lambda (item)
                            (let ((entry (buffer-list-item-entry item)))
                              (unless (buffer-list-entry-heading-p entry)
                                (buffer-list-entry-buffer entry))))
                     :test #'eq)))
      (lem/multi-column-list::multi-column-list/first)
      (dotimes (_ index)
        (lem/multi-column-list::multi-column-list/down)))))

(defun buffer-list-rebuild-snapshot (component)
  (let ((focused-buffer (buffer-list-current-buffer component))
        (marks (buffer-list-record-marks component))
        (items
          (mapcar #'lem/multi-column-list::wrap
                  (buffer-list-grouped-entries))))
    (clrhash (buffer-list-component-recency-ranks component))
    (clrhash (buffer-list-component-deletion-items component))
    (setf (buffer-list-component-all-items component) items)
    (loop :with rank := 0
          :for item :in items
          :for entry := (buffer-list-item-entry item)
          :unless (buffer-list-entry-heading-p entry)
            :do
               (let* ((buffer (buffer-list-entry-buffer entry))
                      (mark (gethash buffer marks)))
                 (setf (gethash buffer
                                (buffer-list-component-recency-ranks component))
                       rank)
                 (incf rank)
                 (when mark
                   (buffer-list-set-item-mark component item mark))))
    (buffer-list-sort-all-items component)
    (buffer-list-refresh component :recompute-columns t)
    (buffer-list-focus-buffer component focused-buffer)
    (message "Ibuffer updated")))

(define-command lem-yath-buffer-list-update () ()
  (buffer-list-rebuild-snapshot
   (lem/multi-column-list::current-multi-column-list)))

(define-command lem-yath-buffer-list-redisplay () ()
  (buffer-list-refresh
   (lem/multi-column-list::current-multi-column-list)
   :recompute-columns t)
  (message "Ibuffer redisplayed"))

(define-command lem-yath-buffer-list-delete-items () ()
  (buffer-list-delete-action-items
   (lem/multi-column-list::current-multi-column-list)))

(define-command lem-yath-buffer-list-execute-deletions () ()
  (let ((component (lem/multi-column-list::current-multi-column-list)))
    (buffer-list-delete-items-now
     component (buffer-list-deletion-action-items component))))

(define-command lem-yath-buffer-list-save-items () ()
  (buffer-list-save-action-items
   (lem/multi-column-list::current-multi-column-list)))

(define-command lem-yath-buffer-list-sort-alphabetic () ()
  (buffer-list-set-sort-mode
   (lem/multi-column-list::current-multi-column-list) :alphabetic))

(define-command lem-yath-buffer-list-sort-recency () ()
  (buffer-list-set-sort-mode
   (lem/multi-column-list::current-multi-column-list) :recency))

(define-command lem-yath-buffer-list-sort-size () ()
  (buffer-list-set-sort-mode
   (lem/multi-column-list::current-multi-column-list) :size))

(define-command lem-yath-buffer-list-sort-filename () ()
  (buffer-list-set-sort-mode
   (lem/multi-column-list::current-multi-column-list) :filename))

(define-command lem-yath-buffer-list-sort-major-mode () ()
  (buffer-list-set-sort-mode
   (lem/multi-column-list::current-multi-column-list) :major-mode))

(define-command lem-yath-buffer-list-invert-sorting () ()
  (let ((component (lem/multi-column-list::current-multi-column-list)))
    (setf (buffer-list-component-sort-reversed-p component)
          (not (buffer-list-component-sort-reversed-p component)))
    (buffer-list-sort-all-items component)
    (buffer-list-refresh component)
    (message "Sorting order ~:[normal~;reversed~]"
             (buffer-list-component-sort-reversed-p component))))

(define-command lem-yath-buffer-list-cycle-sorting () ()
  (let* ((component (lem/multi-column-list::current-multi-column-list))
         (mode (buffer-list-component-sort-mode component))
         (tail (member mode *buffer-list-sort-mode-cycle*))
         (next (or (second tail) (first *buffer-list-sort-mode-cycle*))))
    (buffer-list-set-sort-mode component next)))

(define-command lem-yath-buffer-list-switch-format () ()
  (let ((component (lem/multi-column-list::current-multi-column-list)))
    (setf (buffer-list-component-format-index component)
          (mod (1+ (buffer-list-component-format-index component)) 2))
    (buffer-list-refresh component :recompute-columns t)
    (message "Buffer-list format ~d of 2"
             (1+ (buffer-list-component-format-index component)))))

(defun buffer-list-move-to-group (component direction)
  (let* ((start (buffer-list-current-item component))
         (move (ecase direction
                 (:forward #'lem/multi-column-list::multi-column-list/down)
                 (:backward #'lem/multi-column-list::multi-column-list/up))))
    (loop :repeat (length
                   (lem/multi-column-list::multi-column-list-items component))
          :do (funcall move)
              (let ((item (buffer-list-current-item component)))
                (when (and item
                           (not (eq item start))
                           (buffer-list-entry-heading-p
                            (buffer-list-item-entry item)))
                  (return item))))))

(define-command lem-yath-buffer-list-next-group () ()
  (buffer-list-move-to-group
   (lem/multi-column-list::current-multi-column-list) :forward))

(define-command lem-yath-buffer-list-previous-group () ()
  (buffer-list-move-to-group
   (lem/multi-column-list::current-multi-column-list) :backward))

(defun buffer-list-kill-selected (window)
  (buffer-list-delete-action-items
   (lem/multi-column-list:multi-column-list-of-window window)))

(defun buffer-list-save-selected (window)
  (buffer-list-save-action-items
   (lem/multi-column-list:multi-column-list-of-window window)))

(defun make-buffer-list-context-menu ()
  (make-instance
   'lem/context-menu:context-menu
   :items
   (list
    (make-instance 'lem/context-menu:item
                   :label "Kill selected buffers"
                   :callback #'buffer-list-kill-selected)
    (make-instance 'lem/context-menu:item
                   :label "Save selected buffers"
                   :callback #'buffer-list-save-selected))))

(define-command lem-yath-list-buffers () ()
  "Open the native buffer chooser in configured Ibuffer group order."
  (let ((component nil))
    (setf component
          (make-instance
           'buffer-list-component
           :columns nil
           :column-function #'buffer-list-columns
           :items (buffer-list-grouped-entries)
           :filter-function
           (lambda (query) (buffer-list-filter-entries component query))
           :select-callback #'buffer-list-select
           :delete-callback #'buffer-list-delete
           :save-callback #'buffer-list-save
           :use-check t
           :context-menu (make-buffer-list-context-menu)))
    (lem/multi-column-list:display component)
    (buffer-list-filter-input-mode nil)
    (buffer-list-picker-mode t)))

;; While entering an `s` filter, printable keys must remain literal even when
;; they are modal commands in the surrounding picker (for example the `o`
;; sorting prefix and `t` mark toggle in a query such as "sort-").
(loop :for code :from (char-code #\a) :to (char-code #\z)
      :for key := (string (code-char code))
      :do (define-key *buffer-list-filter-input-mode-keymap* key
            'lem/multi-column-list::multi-column-list/default))
(loop :for code :from (char-code #\A) :to (char-code #\Z)
      :for key := (string (code-char code))
      :do (define-key *buffer-list-filter-input-mode-keymap* key
            'lem/multi-column-list::multi-column-list/default))
(loop :for code :from (char-code #\0) :to (char-code #\9)
      :for key := (string (code-char code))
      :do (define-key *buffer-list-filter-input-mode-keymap* key
            'lem/multi-column-list::multi-column-list/default))
(dolist (key '("-" "." "," "[" "]" "/" "'" "\"" ";" ":" "_" "*"
               "+" "=" "!" "@" "#" "$" "%" "^" "&" "(" ")" "{"
               "}" "<" ">" "?" "\\" "|" "`" "~"))
  (define-key *buffer-list-filter-input-mode-keymap* key
    'lem/multi-column-list::multi-column-list/default))
(define-key *buffer-list-filter-input-mode-keymap* "Space"
  'lem/multi-column-list::multi-column-list/default)
(define-key *buffer-list-filter-input-mode-keymap* "Backspace"
  'lem/multi-column-list::multi-column-list/delete-previous-char)
(define-key *buffer-list-filter-input-mode-keymap* "C-h"
  'lem/multi-column-list::multi-column-list/delete-previous-char)
(define-key *buffer-list-filter-input-mode-keymap* "Return"
  'lem-yath-buffer-list-accept-input-filter)
(define-key *buffer-list-filter-input-mode-keymap* "Escape"
  'lem-yath-buffer-list-cancel-input-filter)
(define-key *buffer-list-filter-input-mode-keymap* "C-g"
  'lem-yath-buffer-list-cancel-input-filter)

(define-key *buffer-list-picker-mode-keymap* "Space"
  'lem-yath-buffer-list-check-and-down)
(define-key *buffer-list-picker-mode-keymap* "M-Space"
  'lem-yath-buffer-list-up-and-check)
(define-key *buffer-list-picker-mode-keymap* "C-k"
  'lem-yath-buffer-list-previous-group)
(define-key *buffer-list-picker-mode-keymap* "C-s"
  'lem-yath-buffer-list-save-items)
(define-key *buffer-list-picker-mode-keymap* "m"
  'lem-yath-buffer-list-mark-forward)
(define-key *buffer-list-picker-mode-keymap* "u"
  'lem-yath-buffer-list-unmark-forward)
(define-key *buffer-list-picker-mode-keymap* "U"
  'lem-yath-buffer-list-unmark-all)
(define-key *buffer-list-picker-mode-keymap* "t"
  'lem-yath-buffer-list-toggle-marks)
(define-key *buffer-list-picker-mode-keymap* "~"
  'lem-yath-buffer-list-toggle-marks)
(define-key *buffer-list-picker-mode-keymap* "d"
  'lem-yath-buffer-list-mark-deletion)
(define-key *buffer-list-picker-mode-keymap* "x"
  'lem-yath-buffer-list-execute-deletions)
(define-key *buffer-list-picker-mode-keymap* "S"
  'lem-yath-buffer-list-save-items)
(define-key *buffer-list-picker-mode-keymap* "g j"
  'lem/multi-column-list::multi-column-list/down)
(define-key *buffer-list-picker-mode-keymap* "g k"
  'lem/multi-column-list::multi-column-list/up)
(define-key *buffer-list-picker-mode-keymap* "g r"
  'lem-yath-buffer-list-update)
(define-key *buffer-list-picker-mode-keymap* "g R"
  'lem-yath-buffer-list-redisplay)
(define-key *buffer-list-picker-mode-keymap* "g o"
  'lem-yath-buffer-list-visit-other-window)
(define-key *buffer-list-picker-mode-keymap* "y b"
  'lem-yath-buffer-list-copy-buffer-name)
(define-key *buffer-list-picker-mode-keymap* "y f"
  'lem-yath-buffer-list-copy-file-name)
(define-key *buffer-list-picker-mode-keymap* "Tab"
  'lem-yath-buffer-list-next-group)
(define-key *buffer-list-picker-mode-keymap* "Shift-Tab"
  'lem-yath-buffer-list-previous-group)
(define-key *buffer-list-picker-mode-keymap* "C-j"
  'lem-yath-buffer-list-next-group)
(define-key *buffer-list-picker-mode-keymap* "] ]"
  'lem-yath-buffer-list-next-group)
(define-key *buffer-list-picker-mode-keymap* "[ ["
  'lem-yath-buffer-list-previous-group)
(define-key *buffer-list-picker-mode-keymap* "q"
  'lem/multi-column-list::multi-column-list/quit)
(define-key *buffer-list-picker-mode-keymap* "s n"
  'lem-yath-buffer-list-start-name-filter)
(define-key *buffer-list-picker-mode-keymap* "s m"
  'lem-yath-buffer-list-start-mode-filter)
(define-key *buffer-list-picker-mode-keymap* "s f"
  'lem-yath-buffer-list-start-filename-filter)
(define-key *buffer-list-picker-mode-keymap* "s b"
  'lem-yath-buffer-list-start-basename-filter)
(define-key *buffer-list-picker-mode-keymap* "s ."
  'lem-yath-buffer-list-start-extension-filter)
(define-key *buffer-list-picker-mode-keymap* "s i"
  'lem-yath-buffer-list-filter-modified)
(define-key *buffer-list-picker-mode-keymap* "s v"
  'lem-yath-buffer-list-filter-visiting-file)
(define-key *buffer-list-picker-mode-keymap* "s p"
  'lem-yath-buffer-list-pop-filter)
(define-key *buffer-list-picker-mode-keymap* "s !"
  'lem-yath-buffer-list-negate-filter)
(define-key *buffer-list-picker-mode-keymap* "s /"
  'lem-yath-buffer-list-disable-filters)
(define-key *buffer-list-picker-mode-keymap* "o a"
  'lem-yath-buffer-list-sort-alphabetic)
(define-key *buffer-list-picker-mode-keymap* "o v"
  'lem-yath-buffer-list-sort-recency)
(define-key *buffer-list-picker-mode-keymap* "o s"
  'lem-yath-buffer-list-sort-size)
(define-key *buffer-list-picker-mode-keymap* "o f"
  'lem-yath-buffer-list-sort-filename)
(define-key *buffer-list-picker-mode-keymap* "o m"
  'lem-yath-buffer-list-sort-major-mode)
(define-key *buffer-list-picker-mode-keymap* "o i"
  'lem-yath-buffer-list-invert-sorting)
(define-key *buffer-list-picker-mode-keymap* ","
  'lem-yath-buffer-list-cycle-sorting)
(define-key *buffer-list-picker-mode-keymap* "`"
  'lem-yath-buffer-list-switch-format)
