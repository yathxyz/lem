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
(defvar *buffer-list-test-lock-alpha* nil)
(defvar *buffer-list-test-lock-beta* nil)
(defvar *buffer-list-test-exit-cleanup-count* 0)
(defvar *buffer-list-test-revert-clean* nil)
(defvar *buffer-list-test-revert-dirty* nil)
(defvar *buffer-list-test-revert-missing* nil)
(defvar *buffer-list-test-occur-alpha* nil)
(defvar *buffer-list-test-occur-beta* nil)
(defvar *buffer-list-test-occur-delete* nil)
(defvar *buffer-list-test-query-alpha* nil)
(defvar *buffer-list-test-query-beta* nil)
(defvar *buffer-list-test-query-delete* nil)
(defvar *buffer-list-test-query-read-only* nil)
(defvar *buffer-list-test-query-expand* nil)
(defvar *buffer-list-test-process* nil)
(defvar *buffer-list-test-old* nil)
(defvar *buffer-list-test-recent* nil)
(defvar *buffer-list-test-never-displayed* nil)

(define-major-mode buffer-list-test-long-mode ()
    (:name "Long Fixture Mode Name"))

(define-major-mode buffer-list-test-sort-a-mode ()
    (:name "Zulu Display Mode"))

(define-major-mode buffer-list-test-sort-m-mode ()
    (:name "Alpha Display Mode"))

(define-major-mode buffer-list-test-sort-z-mode ()
    (:name "Middle Display Mode"))

(define-major-mode buffer-list-test-derived-parent-mode ()
    (:name "Ibuffer Parent Fixture"))

(define-major-mode buffer-list-test-derived-child-mode
    buffer-list-test-derived-parent-mode
    (:name "Ibuffer Child Fixture"))

(defun buffer-list-test-stop-process ()
  (when *buffer-list-test-process*
    (when (ignore-errors (uiop:process-alive-p *buffer-list-test-process*))
      (ignore-errors (uiop:terminate-process *buffer-list-test-process*)))
    (ignore-errors (uiop:wait-process *buffer-list-test-process*))
    (setf *buffer-list-test-process* nil)))

(defun buffer-list-test-exit-cleanup-probe ()
  (incf *buffer-list-test-exit-cleanup-count*))

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
     "FILTER stack=~{~a~^,+~} visible=~{~a~^,~} saved=~{~a~^,~} groups=~{~a~^,~} saved-groups=~{~a~^,~}"
     filters visible
     (mapcar #'car *buffer-list-saved-filters*)
     (buffer-list-filter-group-names component)
     (mapcar #'car *buffer-list-saved-filter-groups*))))

(define-command lem-yath-test-buffer-list-old-state () ()
  (let* ((probe (make-buffer "buffer-list-old-boundary-probe"))
         (now (get-universal-time))
         (threshold (* 60 60 (variable-value 'ibuffer-old-time :global))))
    (unwind-protect
         (progn
           (setf (buffer-list-buffer-display-time probe) nil)
           (let ((never (buffer-list-old-buffer-p probe now)))
             (setf (buffer-list-buffer-display-time probe) (- now threshold))
             (let ((boundary (buffer-list-old-buffer-p probe now))
                   (after (buffer-list-old-buffer-p probe (1+ now))))
               (buffer-list-test-log
                "OLD never=~a boundary=~a after=~a binding=~a picker-displayed=~a"
                (if never "yes" "no")
                (if boundary "yes" "no")
                (if after "yes" "no")
                (buffer-list-test-binding ".")
                (if (buffer-list-buffer-display-time (current-buffer))
                    "yes" "no")))))
      (delete-buffer probe))))

(define-command lem-yath-test-buffer-list-create-late-buffer () ()
  (setf *buffer-list-test-late-buffer*
        (or *buffer-list-test-late-buffer*
            (make-buffer "buffer-list-late-buffer")))
  (buffer-list-test-log "LATE created=yes"))

(define-command lem-yath-test-buffer-list-prepare-row-visibility () ()
  (dolist (spec '((tmp-hide "buffer-list-tmp-hide")
                  (tmp-show "buffer-list-tmp-show")
                  (tmp-peer "buffer-list-tmp-peer")
                  (kill-line-a "buffer-list-kill-line-a")
                  (kill-line-b "buffer-list-kill-line-b")
                  (kill-line-delete "buffer-list-kill-line-delete")))
    (unless (get-buffer (second spec))
      (buffer-list-test-make-buffer (first spec) (second spec))))
  (buffer-list-test-log "ROW-VISIBILITY-PREPARED"))

(define-command lem-yath-test-buffer-list-killring () ()
  (buffer-list-test-log
   "COPY value=~a"
   (completion-path-display-string
    (or (lem/common/killring:peek-killring-item (current-killring) 0) ""))))

(defun buffer-list-test-window-axis (windows)
  (cond
    ((< (length windows) 2) "single")
    ((and (apply #'= (mapcar #'window-x windows))
          (apply #'= (mapcar #'window-width windows)))
     "stacked")
    ((and (apply #'= (mapcar #'window-y windows))
          (apply #'= (mapcar #'window-height windows)))
     "side-by-side")
    (t "mixed")))

(define-command lem-yath-test-buffer-list-window-state () ()
  (let ((windows (window-list)))
    (buffer-list-test-log
     "WINDOW count=~d current=~a buffers=~{~a~^,~} axis=~a layout=~{~a~^;~}"
     (length windows)
     (completion-path-display-string (buffer-name (current-buffer)))
     (mapcar (lambda (window)
               (completion-path-display-string
                (buffer-name (window-buffer window))))
             windows)
     (buffer-list-test-window-axis windows)
     (mapcar
      (lambda (window)
        (format nil "~a@~d,~d,~dx~d"
                (completion-path-display-string
                 (buffer-name (window-buffer window)))
                (window-x window) (window-y window)
                (window-width window) (window-height window)))
      windows))))

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

(define-command lem-yath-test-buffer-list-lock-state () ()
  (buffer-list-test-log
   "LOCK alpha=~a:~a beta=~a:~a query-hooks=~d exit-hooks=~d cleanup=~d"
   (if (member *buffer-list-test-lock-alpha* (buffer-list) :test #'eq)
       "live" "dead")
   (if (buffer-list-buffer-locked-p *buffer-list-test-lock-alpha*)
       "locked" "unlocked")
   (if (member *buffer-list-test-lock-beta* (buffer-list) :test #'eq)
       "live" "dead")
   (if (buffer-list-buffer-locked-p *buffer-list-test-lock-beta*)
       "locked" "unlocked")
   (count 'buffer-list-kill-buffer-query
          (variable-value 'kill-buffer-query-hook :global t)
          :key #'car :test #'eq)
   (count 'buffer-list-exit-query *exit-editor-hook* :key #'car :test #'eq)
   *buffer-list-test-exit-cleanup-count*))

(define-command lem-yath-test-buffer-list-picker-bindings () ()
  (let ((windows (window-list)))
    (buffer-list-test-log
     "PICKER-BINDINGS backspace=~a control-h=~a delete=~a diff=~a jump=~a meta-jump=~a group-jump=~a other-noselect=~a one-window=~a view=~a view-g=~a view-horizontal=~a occur=~a occur-meta=~a isearch=~a isearch-regexp=~a query=~a query-regexp=~a mode=~a derived=~a starred=~a size-lt=~a size-gt=~a content=~a tmp-hide=~a tmp-show=~a kill-lines=~a lock=~a mark-locked=~a current-popup=~a ordinary-count=~d ordinary-buffers=~{~a~^,~}"
     (buffer-list-test-binding "Backspace")
     (buffer-list-test-binding "C-h")
     (buffer-list-test-binding "Delete")
     (buffer-list-test-binding "=")
     (buffer-list-test-binding "J")
     (buffer-list-test-binding "M-g")
     (buffer-list-test-binding "M-j")
     (buffer-list-test-binding "C-o")
     (buffer-list-test-binding "M-o")
     (buffer-list-test-binding "A")
     (buffer-list-test-binding "g v")
     (buffer-list-test-binding "g V")
     (buffer-list-test-binding "O")
     (buffer-list-test-binding "M-s a C-o")
     (buffer-list-test-binding "M-s a C-s")
     (buffer-list-test-binding "M-s a M-C-s")
     (buffer-list-test-binding "Q")
     (buffer-list-test-binding "I")
     (buffer-list-test-binding "s Return")
     (buffer-list-test-binding "s M")
     (buffer-list-test-binding "s *")
     (buffer-list-test-binding "s <")
     (buffer-list-test-binding "s >")
     (buffer-list-test-binding "s c")
     (buffer-list-test-binding "-")
     (buffer-list-test-binding "+")
     (buffer-list-test-binding "K")
     (buffer-list-test-binding "L")
     (buffer-list-test-binding "% L")
     (if (floating-window-p (current-window)) "yes" "no")
     (length windows)
     (mapcar (lambda (window)
               (completion-path-display-string
                (buffer-name (window-buffer window))))
             windows))))

(define-command lem-yath-test-buffer-list-occur-state () ()
  (let* ((occur (get-buffer *buffer-list-occur-buffer-name*))
         (selected-p (and occur (eq occur (current-buffer))))
         (point (and selected-p
                     (copy-point (current-point) :temporary)))
         (targets
           (when point
             (line-start point)
             (text-property-at point :buffer-list-occur-targets)))
         (target (first targets))
         (target-live-p
           (and target
                (not (deleted-buffer-p
                      (buffer-list-occur-target-buffer target)))
                (alive-point-p (buffer-list-occur-target-start target)))))
    (buffer-list-test-log
     "OCCUR live=~a current=~a mode=~a readonly=~a modified=~a line=~a row-source=~a row-line=~a target-count=~d sources=~{~a~^,~} windows=~{~a~^,~} text=~a"
     (if occur "yes" "no")
     (completion-path-display-string (buffer-name (current-buffer)))
     (if occur (buffer-major-mode occur) "none")
     (if (and occur (buffer-read-only-p occur)) "yes" "no")
     (if (and occur (buffer-modified-p occur)) "yes" "no")
     (if point (line-number-at-point point) 0)
     (if target
         (completion-path-display-string
          (buffer-name (buffer-list-occur-target-buffer target)))
         "none")
     (if target-live-p
         (line-number-at-point (buffer-list-occur-target-start target))
         (if target -1 0))
     (length targets)
     (if occur
         (mapcar (lambda (buffer)
                   (completion-path-display-string (buffer-name buffer)))
                 (buffer-value occur :lem-yath-buffer-list-occur-sources))
         nil)
     (mapcar (lambda (window)
               (completion-path-display-string
                (buffer-name (window-buffer window))))
             (window-list))
     (if occur
         (completion-path-display-string
          (points-to-string (buffer-start-point occur)
                            (buffer-end-point occur)))
         ""))))

(defun buffer-list-test-occur-line-target-at-point ()
  (buffer-list-occur-edit-target-for-change
   (current-buffer) (current-point) 0))

(defun buffer-list-test-occur-position-source-line (source line)
  (let ((target
          (find-if
           (lambda (target)
             (and (eq source (buffer-list-occur-line-target-buffer target))
                  (= line
                     (line-number-at-point
                      (buffer-list-occur-line-target-source-start target)))))
           (buffer-value (current-buffer)
                         :lem-yath-buffer-list-occur-line-targets))))
    (unless (and target (buffer-list-occur-line-target-live-p target))
      (editor-error "No live Occur row for source line ~d" line))
    (move-point (current-point)
                (buffer-list-occur-line-target-result-start target))))

(define-command lem-yath-test-buffer-list-occur-first-edit-row () ()
  (buffer-list-test-occur-position-source-line
   *buffer-list-test-occur-alpha* 2))

(define-command lem-yath-test-buffer-list-occur-control-edit-row () ()
  (buffer-list-test-occur-position-source-line
   *buffer-list-test-occur-alpha* 9))

(define-command lem-yath-test-buffer-list-restore-occur-name () ()
  (buffer-rename (current-buffer) *buffer-list-occur-buffer-name*))

(define-command lem-yath-test-buffer-list-occur-edit-state () ()
  (let* ((result (current-buffer))
         (target (ignore-errors
                   (buffer-list-test-occur-line-target-at-point)))
         (line-targets
           (buffer-value result :lem-yath-buffer-list-occur-line-targets))
         (owned
           (remove-if-not #'buffer-list-occur-owned-buffer-p (buffer-list))))
    (buffer-list-test-log
     "OCCUR-EDIT current=~a mode=~a readonly=~a modified=~a line=~d column=~d target-source=~a target-line=~d line-targets=~d live-line-targets=~d owned=~{~a~^,~} alpha-readonly=~a alpha-modified=~a result=~a alpha=~a beta=~a"
     (completion-path-display-string (buffer-name result))
     (buffer-major-mode result)
     (if (buffer-read-only-p result) "yes" "no")
     (if (buffer-modified-p result) "yes" "no")
     (line-number-at-point (current-point))
     (point-column (current-point))
     (if target
         (completion-path-display-string
          (buffer-name (buffer-list-occur-line-target-buffer target)))
         "none")
     (if target
         (line-number-at-point
          (buffer-list-occur-line-target-source-start target))
         0)
     (length line-targets)
     (count-if #'buffer-list-occur-line-target-live-p line-targets)
     (mapcar (lambda (buffer)
               (completion-path-display-string (buffer-name buffer)))
             owned)
     (if (buffer-read-only-p *buffer-list-test-occur-alpha*) "yes" "no")
     (if (buffer-modified-p *buffer-list-test-occur-alpha*) "yes" "no")
     (completion-path-display-string
      (points-to-string (buffer-start-point result) (buffer-end-point result)))
     (completion-path-display-string
      (points-to-string (buffer-start-point *buffer-list-test-occur-alpha*)
                        (buffer-end-point *buffer-list-test-occur-alpha*)))
     (completion-path-display-string
      (points-to-string (buffer-start-point *buffer-list-test-occur-beta*)
                        (buffer-end-point *buffer-list-test-occur-beta*))))))

(define-command lem-yath-test-buffer-list-occur-toggle-source-read-only () ()
  (let* ((target (or (buffer-list-test-occur-line-target-at-point)
                     (editor-error "Point is not on an editable Occur row")))
         (source (buffer-list-occur-line-target-buffer target)))
    (setf (buffer-read-only-p source) (not (buffer-read-only-p source)))))

(defun buffer-list-test-occur-refuse-source-change (point change)
  (declare (ignore change))
  (let ((buffer (point-buffer point)))
    (remove-hook (variable-value 'before-change-functions :buffer buffer)
                 'buffer-list-test-occur-refuse-source-change))
  (editor-error "Fixture refused source change"))

(define-command lem-yath-test-buffer-list-occur-refuse-next-source-change () ()
  (let* ((target (or (buffer-list-test-occur-line-target-at-point)
                     (editor-error "Point is not on an editable Occur row")))
         (source (buffer-list-occur-line-target-buffer target)))
    (add-hook (variable-value 'before-change-functions :buffer source)
              'buffer-list-test-occur-refuse-source-change)))

(define-command lem-yath-test-buffer-list-occur-shift-source () ()
  (let* ((target (first (buffer-list-occur-current-targets)))
         (buffer (buffer-list-occur-target-buffer target)))
    (buffer-list-occur-validate-target target)
    (with-buffer-read-only buffer nil
      (insert-string (buffer-start-point buffer)
                     (format nil "inserted before match~%")))))

(define-command lem-yath-test-buffer-list-occur-kill-source () ()
  (let ((target (first (buffer-list-occur-current-targets))))
    (buffer-list-occur-validate-target target)
    (let ((buffer (buffer-list-occur-target-buffer target)))
      ;; This disposable source was made dirty by the live-point test.  Avoid a
      ;; confirmation prompt so the following physical Return tests the stale
      ;; target rather than answering that prompt.
      (buffer-mark-saved buffer)
      (kill-buffer buffer))))

(defmethod execute :after
    (mode (command lem-yath-buffer-list-occur-visit) argument)
  (declare (ignore mode command argument))
  (buffer-list-test-log
   "OCCUR-VISIT current=~a line=~d column=~d"
   (completion-path-display-string (buffer-name (current-buffer)))
   (line-number-at-point (current-point))
   (point-column (current-point))))

(defun buffer-list-test-occur-refused-p (thunk)
  (handler-case
      (progn (funcall thunk) nil)
    (editor-error () t)))

(define-command lem-yath-test-buffer-list-occur-bounds () ()
  (let* ((occur (get-buffer *buffer-list-occur-buffer-name*))
         (before (and occur
                      (points-to-string (buffer-start-point occur)
                                        (buffer-end-point occur))))
         (per-buffer-p
           (let ((*buffer-list-occur-buffer-character-limit* 1)
                 (*buffer-list-occur-total-character-limit*
                   most-positive-fixnum))
             (buffer-list-test-occur-refused-p
              (lambda ()
                (buffer-list-occur-run
                 nil (list *buffer-list-test-occur-alpha*) "Needle" 0)))))
         (total-p
           (let ((*buffer-list-occur-buffer-character-limit*
                   most-positive-fixnum)
                 (*buffer-list-occur-total-character-limit* 1))
             (buffer-list-test-occur-refused-p
              (lambda ()
                (buffer-list-occur-run
                 nil (list *buffer-list-test-occur-alpha*) "Needle" 0)))))
         (clone-total-p
           (let ((*buffer-list-occur-buffer-character-limit*
                   most-positive-fixnum)
                 (*buffer-list-occur-total-character-limit* 1))
             (buffer-list-test-occur-refused-p
              (lambda ()
                (lem-yath-buffer-list-occur-clone))))))
    (buffer-list-test-log
     "OCCUR-BOUNDS per=~a total=~a clone-total=~a preserved=~a"
     (if per-buffer-p "yes" "no")
     (if total-p "yes" "no")
     (if clone-total-p "yes" "no")
     (if (and occur
              (string= before
                       (points-to-string (buffer-start-point occur)
                                         (buffer-end-point occur))))
         "yes"
         "no"))))

(define-command lem-yath-test-buffer-list-occur-source-zero-match () ()
  (let ((occur (get-buffer *buffer-list-occur-buffer-name*)))
    (unless (buffer-list-occur-owned-buffer-p occur)
      (editor-error "No owned Ibuffer Occur result"))
    (buffer-list-occur-run
     nil (list occur) "definitely-no-match-in-owned-occur-source" 0)
    (buffer-list-test-log
     "OCCUR-SOURCE-ZERO source-live=~a canonical-live=~a renamed=~a"
     (if (deleted-buffer-p occur) "no" "yes")
     (if (get-buffer *buffer-list-occur-buffer-name*) "yes" "no")
     (if (and (not (deleted-buffer-p occur))
              (not (string= (buffer-name occur)
                            *buffer-list-occur-buffer-name*)))
         "yes"
         "no"))))

(defun buffer-list-test-mode-active-p (buffer mode)
  (and buffer
       (not (deleted-buffer-p buffer))
       (mode-active-p buffer mode)))

(define-command lem-yath-test-buffer-list-multi-isearch-state () ()
  (let* ((session *buffer-list-multi-isearch-session*)
         (buffers (and session
                       (buffer-list-multi-isearch-session-buffers session))))
    (buffer-list-test-log
     "M-ISEARCH active=~a native=~a current=~a line=~d column=~d regexp=~a string=~a next=~a previous=~a abort=~a sources=~{~a~^,~} source-modes=~{~a~^,~}"
     (if session "yes" "no")
     (if (mode-active-p (current-buffer) 'lem/isearch:isearch-mode)
         "yes"
         "no")
     (completion-path-display-string (buffer-name (current-buffer)))
     (line-number-at-point (current-point))
     (point-column (current-point))
     (if (and session
              (buffer-list-multi-isearch-session-regexp-p session))
         "yes"
         "no")
     (completion-path-display-string
      (if (boundp 'lem/isearch::*isearch-string*)
          lem/isearch::*isearch-string*
          ""))
     (buffer-list-test-binding "C-s")
     (buffer-list-test-binding "C-r")
     (buffer-list-test-binding "C-g")
     (mapcar (lambda (buffer)
               (completion-path-display-string (buffer-name buffer)))
             buffers)
     (mapcar
      (lambda (buffer)
        (format nil "~a:~a/~a"
                (completion-path-display-string (buffer-name buffer))
                (if (buffer-list-test-mode-active-p
                     buffer 'lem/isearch:isearch-mode)
                    "native"
                    "no-native")
                (if (buffer-list-test-mode-active-p
                     buffer 'buffer-list-multi-isearch-mode)
                    "multi"
                    "no-multi")))
      buffers))))

(defun buffer-list-test-query-buffer-state (buffer)
  (format nil "~a:~a:~a"
          (if (buffer-modified-p buffer) "modified" "clean")
          (if (buffer-read-only-p buffer) "readonly" "writable")
          (completion-path-display-string
           (points-to-string (buffer-start-point buffer)
                             (buffer-end-point buffer)))))

(define-command lem-yath-test-buffer-list-query-state () ()
  (let* ((component (lem/multi-column-list::current-multi-column-list))
         (source-window (buffer-list-source-window component)))
    (buffer-list-test-log
     "QUERY source=~a windows=~d alpha=~a beta=~a delete=~a readonly=~a expand=~a"
     (completion-path-display-string
      (buffer-name (window-buffer source-window)))
     (length (window-list))
     (buffer-list-test-query-buffer-state *buffer-list-test-query-alpha*)
     (buffer-list-test-query-buffer-state *buffer-list-test-query-beta*)
     (buffer-list-test-query-buffer-state *buffer-list-test-query-delete*)
     (buffer-list-test-query-buffer-state *buffer-list-test-query-read-only*)
     (buffer-list-test-query-buffer-state *buffer-list-test-query-expand*))))

(define-command lem-yath-test-buffer-list-multi-isearch-lifecycle () ()
  (buffer-list-test-log
   "M-ISEARCH-LIFECYCLE active=~a current=~a line=~d column=~d alpha=~a/~a beta=~a/~a literal-top=~a regexp-recorded=~a"
   (if *buffer-list-multi-isearch-session* "yes" "no")
   (completion-path-display-string (buffer-name (current-buffer)))
   (line-number-at-point (current-point))
   (point-column (current-point))
   (if (buffer-list-test-mode-active-p
        *buffer-list-test-occur-alpha* 'lem/isearch:isearch-mode)
       "native"
       "no-native")
   (if (buffer-list-test-mode-active-p
        *buffer-list-test-occur-alpha* 'buffer-list-multi-isearch-mode)
       "multi"
       "no-multi")
   (if (buffer-list-test-mode-active-p
        *buffer-list-test-occur-beta* 'lem/isearch:isearch-mode)
       "native"
       "no-native")
   (if (buffer-list-test-mode-active-p
        *buffer-list-test-occur-beta* 'buffer-list-multi-isearch-mode)
       "multi"
       "no-multi")
   (completion-path-display-string (or (first *literal-search-history*) ""))
   (if (member "NEEDLE beta (upper|missing)"
               *regexp-search-history* :test #'string=)
       "yes"
       "no")))

(define-command lem-yath-test-buffer-list-occur-bindings () ()
  (buffer-list-test-log
   "OCCUR-BINDINGS return=~a control-return=~a shift-return=~a meta-return=~a other=~a next=~a previous=~a control-next=~a control-previous=~a edit=~a edit-toggle=~a rename=~a clone=~a quit=~a"
   (buffer-list-test-binding "Return")
   (buffer-list-test-binding "C-c C-c")
   (buffer-list-test-binding "S-Return")
   (buffer-list-test-binding "M-Return")
   (buffer-list-test-binding "g o")
   (buffer-list-test-binding "g j")
   (buffer-list-test-binding "g k")
   (buffer-list-test-binding "C-j")
   (buffer-list-test-binding "C-k")
   (buffer-list-test-binding "i")
   (buffer-list-test-binding "C-x C-q")
   (buffer-list-test-binding "r")
   (buffer-list-test-binding "c")
   (buffer-list-test-binding "q")))

(define-command lem-yath-test-buffer-list-select-occur-window () ()
  (let* ((buffer (get-buffer *buffer-list-occur-buffer-name*))
         (window (and buffer
                      (find buffer (window-list)
                            :key #'window-buffer
                            :test #'eq))))
    (unless window
      (editor-error "No displayed Ibuffer Occur result"))
    (switch-to-window window)))

(define-command lem-yath-test-buffer-list-diff-state () ()
  (let ((buffer (get-buffer *buffer-list-diff-buffer-name*)))
    (buffer-list-test-log
     "DIFF live=~a current=~a mode=~a readonly=~a modified=~a text=~a"
     (if buffer "yes" "no")
     (completion-path-display-string (buffer-name (current-buffer)))
     (if buffer (buffer-major-mode buffer) "none")
     (if (and buffer (buffer-read-only-p buffer)) "yes" "no")
     (if (and buffer (buffer-modified-p buffer)) "yes" "no")
     (if buffer
         (completion-path-display-string
          (points-to-string (buffer-start-point buffer)
                            (buffer-end-point buffer)))
         ""))))

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
(setf *buffer-list-saved-filters* nil)
(setf *buffer-list-saved-filter-groups* nil)
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
      (buffer-list-test-make-buffer
       'op-alpha "buffer-list-op-alpha"
       'buffer-list-test-derived-child-mode))
(setf *buffer-list-test-op-beta*
      (buffer-list-test-make-buffer
       'op-beta "buffer-list-op-beta"
       'buffer-list-test-derived-parent-mode))
(buffer-list-test-set-content
 *buffer-list-test-op-alpha* (format nil "unique filter needle alpha~%") t)
(buffer-list-test-set-content
 *buffer-list-test-op-beta* (format nil "ordinary beta content~%") t)
(setf *buffer-list-test-process*
      (uiop:launch-program '("sleep" "600")
                           :input nil :output nil :error-output nil)
      (buffer-value *buffer-list-test-op-alpha* 'process)
      *buffer-list-test-process*
      (buffer-value *buffer-list-test-op-beta*
                    :lem-yath-compilation-session)
      (make-compilation-session
       :buffer *buffer-list-test-op-beta*
       :process *buffer-list-test-process*
       :control-armed-p t
       :state :running))
(let ((buffer (buffer-list-test-buffer 'help)))
  (buffer-list-test-set-content
   buffer (format nil "unique filter needle alpha~%") t))
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
(setf *buffer-list-test-old*
      (buffer-list-test-make-buffer
       'mark-old-hit "buffer-list-mark-old-hit")
      *buffer-list-test-recent*
      (buffer-list-test-make-buffer
       'mark-old-recent "buffer-list-mark-old-recent")
      *buffer-list-test-never-displayed*
      (buffer-list-test-make-buffer
       'mark-old-never "buffer-list-mark-old-never"))
(let ((now (get-universal-time)))
  (setf (buffer-list-buffer-display-time *buffer-list-test-old*)
        (- now (* 73 60 60))
        (buffer-list-buffer-display-time *buffer-list-test-recent*) now
        (buffer-list-buffer-display-time *buffer-list-test-never-displayed*) nil))
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

(let ((buffer
        (buffer-list-test-make-buffer 'view-alpha "buffer-list-view-alpha")))
  (setf (buffer-directory buffer)
        (uiop:pathname-directory-pathname
         (uiop:getenv "LEM_YATH_BUFFER_LIST_DIRECTORY_HIT"))))
(let ((buffer
        (buffer-list-test-make-buffer 'view-beta "buffer-list-view-beta")))
  (setf (buffer-directory buffer)
        (uiop:pathname-directory-pathname
         (uiop:getenv "LEM_YATH_BUFFER_LIST_DIRECTORY_MISS"))))
(buffer-list-test-make-buffer 'view-delete "buffer-list-view-delete")

(setf *buffer-list-test-occur-alpha*
      (buffer-list-test-make-buffer
       'occur-alpha "buffer-list-occur-alpha"))
(buffer-list-test-set-content
 *buffer-list-test-occur-alpha*
 (format nil
         "zero~%Needle alpha mixed~%after~%far~%needle alpha and needle again~%after-two~%multi start~%finish token~%control~c~c~cneedle~%"
         #\Tab (code-char #x9B) (code-char #x202E))
 t)
(setf *buffer-list-test-occur-beta*
      (buffer-list-test-make-buffer
       'occur-beta "buffer-list-occur-beta"))
(buffer-list-test-set-content
 *buffer-list-test-occur-beta*
 (format nil "needle beta lower~%tail~%NEEDLE beta upper~%") t)
(setf *buffer-list-test-occur-delete*
      (buffer-list-test-make-buffer
       'occur-delete "buffer-list-occur-delete"))
(buffer-list-test-set-content
 *buffer-list-test-occur-delete*
 (format nil "needle forbidden deletion~%") t)

(define-command lem-yath-test-buffer-list-prepare-query () ()
  (setf *buffer-list-test-query-alpha*
        (buffer-list-test-make-buffer
         'query-alpha "buffer-list-query-alpha"))
  (buffer-list-test-set-content
   *buffer-list-test-query-alpha*
   (format nil "foo alpha one~%FOO alpha two~%foo alpha three~%") t)
  (setf *buffer-list-test-query-beta*
        (buffer-list-test-make-buffer
         'query-beta "buffer-list-query-beta"))
  (buffer-list-test-set-content
   *buffer-list-test-query-beta*
   (format nil "foo beta one~%bar 42~%BAR 99~%") t)
  (setf *buffer-list-test-query-delete*
        (buffer-list-test-make-buffer
         'query-delete "buffer-list-query-delete"))
  (buffer-list-test-set-content
   *buffer-list-test-query-delete*
   (format nil "foo forbidden deletion~%bar 77~%") t)
  (setf *buffer-list-test-query-read-only*
        (buffer-list-test-make-buffer
         'query-read-only "buffer-list-query-read-only"))
  (buffer-list-test-set-content
   *buffer-list-test-query-read-only*
   (format nil "foo read only~%") t)
  (setf (buffer-read-only-p *buffer-list-test-query-read-only*) t)
  (setf *buffer-list-test-query-expand*
        (buffer-list-test-make-buffer
         'query-expand "buffer-list-query-expand"))
  (buffer-list-test-set-content
   *buffer-list-test-query-expand*
   (format nil "foo-one~%FOO-TWO~%Foo-Three~%") t)
  (buffer-list-test-log "QUERY-PREPARED"))

(define-command lem-yath-test-buffer-list-prepare-lock () ()
  (setf *buffer-list-test-lock-alpha*
        (or (get-buffer "buffer-list-lock-alpha")
            (buffer-list-test-make-buffer
             'lock-alpha "buffer-list-lock-alpha"))
        *buffer-list-test-lock-beta*
        (or (get-buffer "buffer-list-lock-beta")
            (buffer-list-test-make-buffer
             'lock-beta "buffer-list-lock-beta")))
  (buffer-list-test-log "LOCK-PREPARED"))

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
(define-key *buffer-list-picker-mode-keymap* "C-c l"
  'lem-yath-test-buffer-list-lock-state)
(define-key *buffer-list-picker-mode-keymap* "C-c o"
  'lem-yath-test-buffer-list-old-state)
(define-key *buffer-list-picker-mode-keymap* "C-c v"
  'lem-yath-test-buffer-list-prepare-row-visibility)
(define-key *buffer-list-picker-mode-keymap* "F2"
  'lem-yath-test-buffer-list-picker-bindings)
(define-key *buffer-list-picker-mode-keymap* "F1"
  'lem-yath-test-buffer-list-revert-state)
(define-key *buffer-list-picker-mode-keymap* "F6"
  'lem-yath-test-buffer-list-prepare-revert)
(define-key *buffer-list-picker-mode-keymap* "F10"
  'lem-yath-test-buffer-list-diff-state)
(define-key *buffer-list-diff-mode-keymap* "F10"
  'lem-yath-test-buffer-list-diff-state)
(define-key lem-vi-mode:*normal-keymap* "F4"
  'lem-yath-test-buffer-list-window-state)
(define-key lem-vi-mode:*normal-keymap* "F10"
  'lem-yath-test-buffer-list-reload)
(define-key *global-keymap* "F2"
  'lem-yath-test-buffer-list-select-occur-window)
(define-key *global-keymap* "F3"
  'lem-yath-test-buffer-list-occur-state)
(define-key *buffer-list-occur-mode-keymap* "F8"
  'lem-yath-test-buffer-list-occur-state)
(define-key *buffer-list-occur-mode-keymap* "F1"
  'lem-yath-test-buffer-list-occur-bindings)
(define-key *buffer-list-occur-mode-keymap* "F6"
  'lem-yath-test-buffer-list-occur-kill-source)
(define-key *buffer-list-occur-mode-keymap* "F7"
  'lem-yath-test-buffer-list-occur-shift-source)
(define-key *buffer-list-occur-mode-keymap* "F4"
  'lem-yath-test-buffer-list-occur-bounds)
(define-key *buffer-list-occur-mode-keymap* "F9"
  'lem-yath-test-buffer-list-occur-source-zero-match)
(define-key *buffer-list-occur-mode-keymap* "F10"
  'lem-yath-test-buffer-list-restore-occur-name)
(define-key *buffer-list-occur-edit-mode-keymap* "F4"
  'lem-yath-test-buffer-list-occur-control-edit-row)
(define-key *buffer-list-occur-edit-mode-keymap* "F5"
  'lem-yath-test-buffer-list-occur-first-edit-row)
(define-key *buffer-list-occur-edit-mode-keymap* "F6"
  'lem-yath-test-buffer-list-occur-toggle-source-read-only)
(define-key *buffer-list-occur-edit-mode-keymap* "F7"
  'lem-yath-test-buffer-list-occur-refuse-next-source-change)
(define-key *buffer-list-occur-edit-mode-keymap* "F8"
  'lem-yath-test-buffer-list-occur-edit-state)
(define-key *buffer-list-occur-mode-keymap* "C-c e"
  'lem-yath-test-buffer-list-occur-edit-state)
(define-key *buffer-list-occur-edit-mode-keymap* "C-c e"
  'lem-yath-test-buffer-list-occur-edit-state)
(define-key *buffer-list-multi-isearch-mode-keymap* "F5"
  'lem-yath-test-buffer-list-multi-isearch-state)
(define-key *global-keymap* "F12"
  'lem-yath-test-buffer-list-multi-isearch-lifecycle)
(define-key *global-keymap* "F11"
  'lem-yath-test-buffer-list-prepare-query)
(define-key *buffer-list-occur-mode-keymap* "F12"
  'lem-yath-test-buffer-list-prepare-lock)
(define-key *buffer-list-picker-mode-keymap* "F5"
  'lem-yath-test-buffer-list-query-state)

(remove-hook *exit-editor-hook* 'buffer-list-test-stop-process)
(add-hook *exit-editor-hook* 'buffer-list-test-stop-process)
(remove-hook *exit-editor-hook* 'buffer-list-test-exit-cleanup-probe)
(add-hook *exit-editor-hook* 'buffer-list-test-exit-cleanup-probe 1000)

(buffer-list-test-log "READY")
