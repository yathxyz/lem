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

(defun make-buffer-list-entry (group buffer first-in-group-p)
  (list group first-in-group-p buffer))

(defun buffer-list-entry-group (entry)
  (first entry))

(defun buffer-list-entry-first-in-group-p (entry)
  (second entry))

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
  "Group BUFFERS like the configured Ibuffer view, omitting empty groups."
  (let ((remaining (copy-list buffers))
        entries)
    (dolist (group *buffer-list-filter-groups*)
      (multiple-value-bind (matching rest)
          (buffer-list-partition remaining (cdr group))
        (setf remaining rest)
        (loop :for buffer :in matching
              :for first-p := t :then nil
              :do (push (make-buffer-list-entry
                         (car group) buffer first-p)
                        entries))))
    (loop :for buffer :in remaining
          :for first-p := t :then nil
          :do (push (make-buffer-list-entry "Default" buffer first-p)
                    entries))
    (nreverse entries)))

(defun buffer-list-filter-entries (query entries)
  "Filter ENTRIES through Lem's established buffer-name/file matcher."
  (let ((by-buffer (make-hash-table :test #'eq)))
    (dolist (entry entries)
      (setf (gethash (buffer-list-entry-buffer entry) by-buffer) entry))
    (loop :for buffer :in
            (completion-buffer
             query (mapcar #'buffer-list-entry-buffer entries))
          :for entry := (gethash buffer by-buffer)
          :when entry :collect entry)))

(defun buffer-list-attributes (buffer)
  (cond ((buffer-read-only-p buffer) (icon-string "lock"))
        ((buffer-modified-p buffer) (icon-string "bullet-point"))
        (t " ")))

(defun buffer-list-columns (component entry)
  (let ((buffer (buffer-list-entry-buffer entry)))
    (list (buffer-list-attributes buffer)
          (if (or (buffer-list-entry-first-in-group-p entry)
                  (plusp
                   (length
                    (lem/multi-column-list::multi-column-list-search-string
                     component))))
              (buffer-list-entry-group entry)
              "")
          (completion-path-display-string (buffer-name buffer))
          (if (buffer-filename buffer)
              (completion-path-display-string (buffer-filename buffer))
              ""))))

(defun buffer-list-select (component entry)
  (lem/multi-column-list:quit component)
  (switch-to-buffer (buffer-list-entry-buffer entry)))

(defun buffer-list-delete (component entry)
  (declare (ignore component))
  (kill-buffer (buffer-list-entry-buffer entry)))

(defun buffer-list-save (component entry)
  (declare (ignore component))
  (save-buffer (buffer-list-entry-buffer entry)))

(defun buffer-list-kill-selected (window)
  (lem/multi-column-list:delete-checked-items
   (lem/multi-column-list:multi-column-list-of-window window)))

(defun buffer-list-save-selected (window)
  (let ((component
          (lem/multi-column-list:multi-column-list-of-window window)))
    (mapc (lambda (entry)
            (save-buffer (buffer-list-entry-buffer entry)))
          (lem/multi-column-list:collect-checked-items component))
    (lem/multi-column-list:update component)))

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
  (let ((entries (buffer-list-grouped-entries)))
    (lem/multi-column-list:display
     (make-instance
      'lem/multi-column-list:multi-column-list
      :columns '("" "Group" "Buffer" "File")
      :column-function #'buffer-list-columns
      :items entries
      :filter-function
      (lambda (query) (buffer-list-filter-entries query entries))
      :select-callback #'buffer-list-select
      :delete-callback
      (lambda (component entry)
        (setf entries (delete entry entries :test #'eq))
        (buffer-list-delete component entry))
      :save-callback #'buffer-list-save
      :use-check t
      :context-menu (make-buffer-list-context-menu)))))
