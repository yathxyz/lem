(in-package :lem-yath)

(defvar *buffer-list-test-report*
  (uiop:getenv "LEM_YATH_BUFFER_LIST_REPORT"))

(defvar *buffer-list-test-buffers* nil)
(defvar *buffer-list-test-save-buffer* nil)
(defvar *buffer-list-test-kill-a* nil)
(defvar *buffer-list-test-kill-b* nil)
(defvar *buffer-list-test-late-buffer* nil)
(defvar *buffer-list-test-op-alpha* nil)
(defvar *buffer-list-test-op-beta* nil)
(defvar *buffer-list-test-revert-clean* nil)
(defvar *buffer-list-test-revert-dirty* nil)
(defvar *buffer-list-test-revert-missing* nil)

(define-major-mode buffer-list-test-long-mode ()
    (:name "Long Fixture Mode Name"))

(define-major-mode buffer-list-test-sort-a-mode ()
    (:name "Zulu Display Mode"))

(define-major-mode buffer-list-test-sort-m-mode ()
    (:name "Alpha Display Mode"))

(define-major-mode buffer-list-test-sort-z-mode ()
    (:name "Middle Display Mode"))

(defun buffer-list-test-log (control &rest arguments)
  (with-open-file (stream *buffer-list-test-report*
                          :direction :output
                          :if-exists :append
                          :if-does-not-exist :create)
    (apply #'format stream control arguments)
    (terpri stream)))

(defun buffer-list-test-make-buffer (label name &optional mode)
  (let ((buffer (or (get-buffer name) (make-buffer name))))
    (when mode
      (setf (buffer-major-mode buffer) mode))
    (push (cons label buffer) *buffer-list-test-buffers*)
    buffer))

(defun buffer-list-test-find-file-buffer (label environment-variable)
  (let ((buffer (find-file-buffer (uiop:getenv environment-variable))))
    (push (cons label buffer) *buffer-list-test-buffers*)
    buffer))

(defun buffer-list-test-mode-symbol (package name)
  (or (find-symbol name package) 'fundamental-mode))

(defun buffer-list-test-buffer (label)
  (cdr (assoc label *buffer-list-test-buffers*)))

(defun buffer-list-test-group-sequence (entries)
  (let (seen result)
    (dolist (entry entries (nreverse result))
      (let ((group (buffer-list-entry-group entry)))
        (unless (member group seen :test #'string=)
          (push group seen)
          (push group result))))))

(defun buffer-list-test-binding (keys)
  (let ((command (find-keybind (lem-core::parse-keyspec keys))))
    (if (symbolp command) (symbol-name command) (princ-to-string command))))

(defun buffer-list-test-report ()
  (let* ((labels '(org tramp emacs ediff dired terminal help mixed target))
         (groups
           (mapcar (lambda (label)
                     (buffer-list-group-name (buffer-list-test-buffer label)))
                   labels))
         (order
           (buffer-list-test-group-sequence (buffer-list-grouped-entries)))
         (subset
           (buffer-list-test-group-sequence
            (buffer-list-grouped-entries
             (list (buffer-list-test-buffer 'org)
                   (buffer-list-test-buffer 'target))))))
    (buffer-list-test-log
     "STATE classify=~{~a~^,~} order=~{~a~^,~} subset=~{~a~^,~} binding=~a definitions=~d"
     groups order subset (buffer-list-test-binding "C-x C-b")
     (length *buffer-list-filter-groups*))
    (destructuring-bind (status name size mode file)
        (buffer-list-primary-columns
         nil
         (make-buffer-list-entry
          "Default" (buffer-list-test-buffer 'long)))
      (let ((wide (buffer-list-fixed-field "12345678901234界尾x" 18)))
        (buffer-list-test-log
         "COLUMNS status=[~a] name=[~a] name-width=~d size=[~a] mode=[~a] mode-width=~d file=[~a] wide=[~a] wide-width=~d"
         status name (lem/common/character:string-width name) size mode
         (lem/common/character:string-width mode) file wide
         (lem/common/character:string-width wide))))))

(define-command lem-yath-test-buffer-list-report () ()
  (buffer-list-test-report))

(define-command lem-yath-test-buffer-list-current () ()
  (buffer-list-test-log
   "CURRENT name=~a file=~a group=~a text=~a"
   (buffer-name (current-buffer))
   (if (buffer-filename (current-buffer))
       (file-namestring (buffer-filename (current-buffer)))
       "none")
   (buffer-list-group-name (current-buffer))
   (completion-path-display-string
    (points-to-string (buffer-start-point (current-buffer))
                      (buffer-end-point (current-buffer))))))

(define-command lem-yath-test-buffer-list-lifecycle () ()
  (buffer-list-test-log
   "LIFECYCLE save-modified=~a kill-a=~a kill-b=~a"
   (if (buffer-modified-p *buffer-list-test-save-buffer*) "yes" "no")
   (if (member *buffer-list-test-kill-a* (buffer-list) :test #'eq)
       "live" "dead")
   (if (member *buffer-list-test-kill-b* (buffer-list) :test #'eq)
       "live" "dead")))

(define-command lem-yath-test-buffer-list-ui-state () ()
  (let* ((component (lem/multi-column-list::current-multi-column-list))
         (names
           (loop :for item :in (buffer-list-component-all-items component)
                 :for entry := (buffer-list-item-entry item)
                 :for name :=
                   (unless (buffer-list-entry-heading-p entry)
                     (buffer-name (buffer-list-entry-buffer entry)))
                 :when (and name
                            (alexandria:starts-with-subseq
                             "buffer-list-sort-" name))
                   :collect name)))
    (buffer-list-test-log
     "UI sort=~(~a~) reverse=~a format=~d columns=~{~a~^,~} order=~{~a~^,~}"
     (buffer-list-component-sort-mode component)
     (if (buffer-list-component-sort-reversed-p component) "yes" "no")
     (buffer-list-component-format-index component)
     (buffer-list-format-columns component)
     names)))

(define-command lem-yath-test-buffer-list-nav-state () ()
  (let* ((component (lem/multi-column-list::current-multi-column-list))
         (focus (buffer-list-current-item component))
         (focus-entry (and focus (buffer-list-item-entry focus)))
         (focus-label
           (cond
             ((null focus-entry) "none")
             ((buffer-list-entry-heading-p focus-entry)
              (format nil "heading:~a" (buffer-list-entry-group focus-entry)))
             (t
              (format nil "buffer:~a"
                      (completion-path-display-string
                       (buffer-name (buffer-list-entry-buffer focus-entry)))))))
         (marks
           (loop :for item :in (buffer-list-component-all-items component)
                 :for entry := (buffer-list-item-entry item)
                 :when (and
                        (not (buffer-list-entry-heading-p entry))
                        (lem/multi-column-list::multi-column-list-item-checked-p
                         item))
                   :collect
                   (format nil "~a:~c"
                           (completion-path-display-string
                           (buffer-name (buffer-list-entry-buffer entry)))
                           (char (buffer-list-item-mark-string component item)
                                 0)))))
    (buffer-list-test-log
     "NAV focus=~a marks=~{~a~^,~}" focus-label marks)))

(define-command lem-yath-test-buffer-list-filter-state () ()
  (let* ((component (lem/multi-column-list::current-multi-column-list))
         (filters
           (mapcar #'buffer-list-filter-description
                   (buffer-list-component-filters component)))
         (visible
           (loop :for item :in
                   (lem/multi-column-list::multi-column-list-items component)
                 :for entry := (buffer-list-item-entry item)
                 :unless (buffer-list-entry-heading-p entry)
                   :collect
                   (completion-path-display-string
                    (buffer-name (buffer-list-entry-buffer entry))))))
    (buffer-list-test-log
     "FILTER stack=~{~a~^,+~} visible=~{~a~^,~}" filters visible)))

(define-command lem-yath-test-buffer-list-create-late-buffer () ()
  (setf *buffer-list-test-late-buffer*
        (or *buffer-list-test-late-buffer*
            (make-buffer "buffer-list-late-buffer")))
  (buffer-list-test-log "LATE created=yes"))

(define-command lem-yath-test-buffer-list-killring () ()
  (buffer-list-test-log
   "COPY value=~a"
   (completion-path-display-string
    (or (lem/common/killring:peek-killring-item (current-killring) 0) ""))))

(define-command lem-yath-test-buffer-list-window-state () ()
  (buffer-list-test-log
   "WINDOW count=~d current=~a buffers=~{~a~^,~}"
   (length (window-list))
   (completion-path-display-string (buffer-name (current-buffer)))
   (mapcar (lambda (window)
             (completion-path-display-string
              (buffer-name (window-buffer window))))
           (window-list))))

(define-command lem-yath-test-buffer-list-operation-state () ()
  (buffer-list-test-log
   "OPS alpha=~a:~a:~a beta=~a:~a:~a relative=~{~a~^,~} tail=~a"
   (buffer-name *buffer-list-test-op-alpha*)
   (if (buffer-modified-p *buffer-list-test-op-alpha*) "modified" "clean")
   (if (buffer-read-only-p *buffer-list-test-op-alpha*) "readonly" "writable")
   (buffer-name *buffer-list-test-op-beta*)
   (if (buffer-modified-p *buffer-list-test-op-beta*) "modified" "clean")
   (if (buffer-read-only-p *buffer-list-test-op-beta*) "readonly" "writable")
   (loop :for buffer :in (buffer-list)
         :when (member buffer
                       (list *buffer-list-test-op-alpha*
                             *buffer-list-test-op-beta*)
                       :test #'eq)
           :collect (buffer-name buffer))
   (buffer-name (car (last (buffer-list))))))

(define-command lem-yath-test-buffer-list-picker-bindings () ()
  (buffer-list-test-log
   "PICKER-BINDINGS backspace=~a control-h=~a delete=~a"
   (buffer-list-test-binding "Backspace")
   (buffer-list-test-binding "C-h")
   (buffer-list-test-binding "Delete")))

(defun buffer-list-test-set-content (buffer content clean-p)
  (with-buffer-read-only buffer nil
    (erase-buffer buffer)
    (insert-string (buffer-start-point buffer) content))
  (when clean-p
    (buffer-mark-saved buffer)))

(define-command lem-yath-test-buffer-list-prepare-revert () ()
  (buffer-list-test-set-content
   *buffer-list-test-revert-clean* (format nil "CLEAN LOCAL~%") t)
  (buffer-list-test-set-content
   *buffer-list-test-revert-dirty* (format nil "DIRTY LOCAL~%") nil)
  (buffer-list-test-set-content
   *buffer-list-test-revert-missing* (format nil "MISSING LOCAL~%") nil)
  (buffer-list-test-log "REVERT-PREPARED"))

(define-command lem-yath-test-buffer-list-revert-state () ()
  (buffer-list-test-log
   "REVERT clean=~a:~a dirty=~a:~a missing=~a:~a"
   (completion-path-display-string
    (points-to-string (buffer-start-point *buffer-list-test-revert-clean*)
                      (buffer-end-point *buffer-list-test-revert-clean*)))
   (if (buffer-modified-p *buffer-list-test-revert-clean*)
       "modified" "clean")
   (completion-path-display-string
    (points-to-string (buffer-start-point *buffer-list-test-revert-dirty*)
                      (buffer-end-point *buffer-list-test-revert-dirty*)))
   (if (buffer-modified-p *buffer-list-test-revert-dirty*)
       "modified" "clean")
   (completion-path-display-string
    (points-to-string (buffer-start-point *buffer-list-test-revert-missing*)
                      (buffer-end-point *buffer-list-test-revert-missing*)))
   (if (buffer-modified-p *buffer-list-test-revert-missing*)
       "modified" "clean")))

(define-command lem-yath-test-buffer-list-reload () ()
  (load (merge-pathnames "src/buffer-list.lisp"
                         (asdf:system-source-directory "lem-yath"))))

(setf *buffer-list-test-buffers* nil)
(buffer-list-test-make-buffer 'org "*Org Src buffer-list*")
(buffer-list-test-make-buffer 'tramp "*tramp-buffer-list*")
(buffer-list-test-make-buffer 'emacs "*Warnings*")
(buffer-list-test-make-buffer 'ediff "*Ediff buffer-list*")
(buffer-list-test-make-buffer
 'dired "buffer-list-directory"
 (buffer-list-test-mode-symbol "LEM/DIRECTORY-MODE/MODE" "DIRECTORY-MODE"))
(buffer-list-test-make-buffer
 'terminal "buffer-list-terminal"
 (buffer-list-test-mode-symbol "LEM-SHELL-MODE" "RUN-SHELL-MODE"))
(buffer-list-test-make-buffer 'help "*Help*")
(buffer-list-test-make-buffer
 'mixed "*Org Src directory-first-match*"
 (buffer-list-test-mode-symbol "LEM/DIRECTORY-MODE/MODE" "DIRECTORY-MODE"))
(push (cons 'target
            (find-file-buffer (uiop:getenv "LEM_YATH_BUFFER_LIST_TARGET")))
      *buffer-list-test-buffers*)
(setf *buffer-list-test-save-buffer*
      (find-file-buffer (uiop:getenv "LEM_YATH_BUFFER_LIST_SAVE_TARGET")))
(with-current-buffer *buffer-list-test-save-buffer*
  (buffer-end (current-point))
  (insert-string (current-point) (format nil "SAVE LOCAL~%")))
(setf *buffer-list-test-kill-a*
      (buffer-list-test-make-buffer 'kill-a "buffer-list-kill-target-a"))
(setf *buffer-list-test-kill-b*
      (buffer-list-test-make-buffer 'kill-b "buffer-list-kill-target-b"))
(setf *buffer-list-test-op-alpha*
      (buffer-list-test-make-buffer 'op-alpha "buffer-list-op-alpha"))
(setf *buffer-list-test-op-beta*
      (buffer-list-test-make-buffer 'op-beta "buffer-list-op-beta"))
(setf *buffer-list-test-revert-clean*
      (buffer-list-test-find-file-buffer
       'revert-clean "LEM_YATH_BUFFER_LIST_REVERT_CLEAN"))
(setf *buffer-list-test-revert-dirty*
      (buffer-list-test-find-file-buffer
       'revert-dirty "LEM_YATH_BUFFER_LIST_REVERT_DIRTY"))
(setf *buffer-list-test-revert-missing*
      (buffer-list-test-make-buffer
       'revert-missing "buffer-list-mark-revert-missing.txt"))
(setf (buffer-filename *buffer-list-test-revert-missing*)
      (uiop:getenv "LEM_YATH_BUFFER_LIST_REVERT_MISSING"))
(lem-yath-test-buffer-list-prepare-revert)
(let ((buffer
        (buffer-list-test-make-buffer
         'mark-modified-hit "buffer-list-mark-modified-hit")))
  (insert-string (buffer-end-point buffer) "modified"))
(buffer-list-test-make-buffer
 'mark-modified-miss "buffer-list-mark-modified-miss")
(let ((buffer
        (buffer-list-test-find-file-buffer
         'mark-unsaved-hit "LEM_YATH_BUFFER_LIST_MARK_UNSAVED_HIT")))
  (insert-string (buffer-end-point buffer) "modified"))
(buffer-list-test-find-file-buffer
 'mark-unsaved-miss "LEM_YATH_BUFFER_LIST_MARK_UNSAVED_MISS")
(buffer-list-test-make-buffer
 'mark-special-hit "*buffer-list-mark-special-hit*")
(buffer-list-test-make-buffer
 'mark-special-miss "buffer-list-mark-special-miss")
(let ((buffer
        (buffer-list-test-make-buffer
         'mark-read-only-hit "buffer-list-mark-read-only-hit")))
  (setf (buffer-read-only-p buffer) t))
(buffer-list-test-make-buffer
 'mark-read-only-miss "buffer-list-mark-read-only-miss")
(buffer-list-test-make-buffer
 'mark-dired-hit "buffer-list-mark-dired-hit"
 (buffer-list-test-mode-symbol "LEM/DIRECTORY-MODE/MODE" "DIRECTORY-MODE"))
(buffer-list-test-make-buffer
 'mark-dired-miss "buffer-list-mark-dired-miss")
(let ((buffer
        (buffer-list-test-make-buffer
         'mark-dissociated-hit "buffer-list-mark-dissociated-hit")))
  (setf (buffer-filename buffer)
        (uiop:getenv "LEM_YATH_BUFFER_LIST_MARK_DISSOCIATED_HIT")))
(let ((buffer
        (buffer-list-test-make-buffer
         'mark-dissociated-miss "buffer-list-mark-dissociated-miss")))
  (setf (buffer-filename buffer)
        (uiop:getenv "LEM_YATH_BUFFER_LIST_MARK_DISSOCIATED_MISS")))
(buffer-list-test-make-buffer
 'mark-help-miss "buffer-list-mark-help-miss")
(let ((buffer
        (buffer-list-test-make-buffer
         'mark-compressed-hit "buffer-list-mark-compressed-hit.GZ")))
  (setf (buffer-filename buffer)
        (uiop:getenv "LEM_YATH_BUFFER_LIST_MARK_COMPRESSED_HIT")))
(let ((buffer
        (buffer-list-test-make-buffer
         'mark-compressed-miss "buffer-list-mark-compressed-miss.txt")))
  (setf (buffer-filename buffer)
        (uiop:getenv "LEM_YATH_BUFFER_LIST_MARK_COMPRESSED_MISS")))
(buffer-list-test-make-buffer
 'control (format nil "ctl~%name"))
(let ((buffer
        (buffer-list-test-make-buffer
         'long "buffer-list-name-that-is-long" 'buffer-list-test-long-mode)))
  (insert-string (buffer-end-point buffer) "x")
  (setf (buffer-read-only-p buffer) t))

(flet ((make-sort-buffer (label name mode size filename)
         (let ((buffer (buffer-list-test-make-buffer label name mode)))
           (setf (buffer-filename buffer) filename)
           (insert-string (buffer-end-point buffer)
                          (make-string size :initial-element #\x))
           buffer)))
  (make-sort-buffer
   'sort-alpha "buffer-list-sort-alpha" 'buffer-list-test-sort-z-mode 30
   (uiop:getenv "LEM_YATH_BUFFER_LIST_SORT_C"))
  (make-sort-buffer
   'sort-middle "buffer-list-sort-middle" 'buffer-list-test-sort-a-mode 20
   (uiop:getenv "LEM_YATH_BUFFER_LIST_SORT_A"))
  (make-sort-buffer
   'sort-zeta "buffer-list-sort-zeta" 'buffer-list-test-sort-m-mode 10
   (uiop:getenv "LEM_YATH_BUFFER_LIST_SORT_B")))

(define-key lem-vi-mode:*normal-keymap* "F5"
  'lem-yath-test-buffer-list-report)
(define-key lem-vi-mode:*normal-keymap* "F6"
  'lem-yath-test-buffer-list-current)
(define-key lem-vi-mode:*normal-keymap* "F7"
  'lem-yath-test-buffer-list-lifecycle)
(define-key lem/multi-column-list::*multi-column-list-mode-keymap* "F7"
  'lem-yath-test-buffer-list-lifecycle)
(define-key *buffer-list-picker-mode-keymap* "F8"
  'lem-yath-test-buffer-list-ui-state)
(define-key *buffer-list-picker-mode-keymap* "F11"
  'lem-yath-test-buffer-list-nav-state)
(define-key *buffer-list-picker-mode-keymap* "F12"
  'lem-yath-test-buffer-list-filter-state)
(define-key *buffer-list-picker-mode-keymap* "F4"
  'lem-yath-test-buffer-list-create-late-buffer)
(define-key *buffer-list-picker-mode-keymap* "F9"
  'lem-yath-test-buffer-list-killring)
(define-key *buffer-list-picker-mode-keymap* "F3"
  'lem-yath-test-buffer-list-operation-state)
(define-key *buffer-list-picker-mode-keymap* "F2"
  'lem-yath-test-buffer-list-picker-bindings)
(define-key *buffer-list-picker-mode-keymap* "F1"
  'lem-yath-test-buffer-list-revert-state)
(define-key *buffer-list-picker-mode-keymap* "F6"
  'lem-yath-test-buffer-list-prepare-revert)
(define-key lem-vi-mode:*normal-keymap* "F4"
  'lem-yath-test-buffer-list-window-state)
(define-key lem-vi-mode:*normal-keymap* "F10"
  'lem-yath-test-buffer-list-reload)

(buffer-list-test-log "READY")
