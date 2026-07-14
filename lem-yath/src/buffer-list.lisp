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
    :accessor buffer-list-component-hidden-groups)))

(define-minor-mode buffer-list-picker-mode
    (:name "buffer-list-picker"
     :keymap *buffer-list-picker-mode-keymap*
     :hide-from-modeline t))

(defmethod initialize-instance :after
    ((component buffer-list-component) &key &allow-other-keys)
  (setf (buffer-list-component-all-items component)
        (copy-list
         (lem/multi-column-list::multi-column-list-items component))))

(defun buffer-list-item-entry (item)
  (lem/multi-column-list::unwrap item))

(defun buffer-list-component-entries (component)
  (mapcar #'buffer-list-item-entry
          (buffer-list-component-all-items component)))

(defun buffer-list-group-hidden-p (component group)
  (member group
          (buffer-list-component-hidden-groups component)
          :test #'string=))

(defun buffer-list-visible-item-p (component item)
  (let ((entry (buffer-list-item-entry item)))
    (or (buffer-list-entry-heading-p entry)
        (not (buffer-list-group-hidden-p
              component (buffer-list-entry-group entry))))))

(defun buffer-list-reset-visible-items (component)
  (setf (lem/multi-column-list::multi-column-list-items component)
        (remove-if-not
         (lambda (item) (buffer-list-visible-item-p component item))
         (buffer-list-component-all-items component))))

(defun buffer-list-filter-entries (component query)
  "Filter COMPONENT's entries through the established buffer matcher."
  (let* ((entries (buffer-list-component-entries component))
         (buffer-entries
           (remove-if #'buffer-list-entry-heading-p entries))
         matching)
    (let ((by-buffer (make-hash-table :test #'eq)))
      (dolist (entry buffer-entries)
        (setf (gethash (buffer-list-entry-buffer entry) by-buffer) entry))
      (dolist (buffer
               (completion-buffer
                query (mapcar #'buffer-list-entry-buffer buffer-entries)))
        (alexandria:when-let ((entry (gethash buffer by-buffer)))
          (push entry matching))))
    ;; Live filtering is a selection view rather than an Ibuffer group view:
    ;; omit headings so Return keeps selecting the first matching buffer.  A
    ;; collapsed group becomes visible to a direct query and is restored when
    ;; the query is cleared.
    (nreverse matching)))

(defun buffer-list-attributes (buffer)
  (cond ((buffer-read-only-p buffer) (icon-string "lock"))
        ((buffer-modified-p buffer) (icon-string "bullet-point"))
        (t " ")))

(defun buffer-list-columns (component entry)
  (if (buffer-list-entry-heading-p entry)
      (list ""
            (format nil "[ ~a~a ]"
                    (buffer-list-entry-group entry)
                    (if (buffer-list-group-hidden-p
                         component (buffer-list-entry-group entry))
                        " ..."
                        ""))
            "")
      (let ((buffer (buffer-list-entry-buffer entry)))
        (list (buffer-list-attributes buffer)
              (completion-path-display-string (buffer-name buffer))
              (if (buffer-filename buffer)
                  (completion-path-display-string (buffer-filename buffer))
                  "")))))

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

(defun buffer-list-toggle-current-check (component)
  (alexandria:when-let ((entry (buffer-list-current-entry component)))
    (unless (buffer-list-entry-heading-p entry)
      (lem/multi-column-list::check-current-item component))))

(define-command lem-yath-buffer-list-check-and-down () ()
  (let ((component (lem/multi-column-list::current-multi-column-list)))
    (buffer-list-toggle-current-check component)
    (lem/multi-column-list::multi-column-list/down)))

(define-command lem-yath-buffer-list-up-and-check () ()
  (let ((component (lem/multi-column-list::current-multi-column-list)))
    (lem/multi-column-list::multi-column-list/up)
    (buffer-list-toggle-current-check component)))

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

(defun buffer-list-delete-action-items (component)
  (let ((items (buffer-list-action-items component)))
    (dolist (item items)
      (let ((entry (buffer-list-item-entry item)))
        (buffer-list-delete component entry)
        (setf (buffer-list-component-all-items component)
              (delete item
                      (buffer-list-component-all-items component)
                      :test #'eq))))
    (when items
      (buffer-list-prune-empty-groups component)
      (buffer-list-reset-visible-items component)
      (lem/multi-column-list:update component))))

(defun buffer-list-save-action-items (component)
  (dolist (item (buffer-list-action-items component))
    (buffer-list-save component (buffer-list-item-entry item)))
  (lem/multi-column-list:update component))

(define-command lem-yath-buffer-list-delete-items () ()
  (buffer-list-delete-action-items
   (lem/multi-column-list::current-multi-column-list)))

(define-command lem-yath-buffer-list-save-items () ()
  (buffer-list-save-action-items
   (lem/multi-column-list::current-multi-column-list)))

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
           :columns '("" "Buffer" "File")
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
    (buffer-list-picker-mode t)))

(define-key *buffer-list-picker-mode-keymap* "Space"
  'lem-yath-buffer-list-check-and-down)
(define-key *buffer-list-picker-mode-keymap* "M-Space"
  'lem-yath-buffer-list-up-and-check)
(define-key *buffer-list-picker-mode-keymap* "C-k"
  'lem-yath-buffer-list-delete-items)
(define-key *buffer-list-picker-mode-keymap* "C-s"
  'lem-yath-buffer-list-save-items)
