(in-package :lem-yath)

(defvar *buffer-list-test-report*
  (uiop:getenv "LEM_YATH_BUFFER_LIST_REPORT"))

(defvar *buffer-list-test-buffers* nil)
(defvar *buffer-list-test-save-buffer* nil)
(defvar *buffer-list-test-kill-a* nil)
(defvar *buffer-list-test-kill-b* nil)

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
(define-key lem-vi-mode:*normal-keymap* "F10"
  'lem-yath-test-buffer-list-reload)

(buffer-list-test-log "READY")
