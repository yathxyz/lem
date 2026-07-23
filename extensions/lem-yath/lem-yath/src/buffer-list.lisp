;;;; Ibuffer-style saved filter groups on Lem's native buffer chooser.

(in-package :lem-yath)

(define-editor-variable buffer-lock-mode nil)
(define-editor-variable ibuffer-old-time 72
  "The number of hours before Ibuffer considers a buffer old.")

(defconstant +buffer-list-display-time-key+
  'lem-yath-buffer-display-time)

(defun buffer-list-buffer-display-time (buffer)
  "Return BUFFER's last window-display time, or NIL if it was never displayed."
  (buffer-value buffer +buffer-list-display-time-key+))

(defun (setf buffer-list-buffer-display-time) (time buffer)
  (setf (buffer-value buffer +buffer-list-display-time-key+) time))

(defun buffer-list-record-display-time (buffer &optional
                                                 (time (get-universal-time)))
  "Record TIME as BUFFER's most recent display in a window."
  (setf (buffer-list-buffer-display-time buffer) time))

(defmethod initialize-instance :around ((window lem-core:window)
                                        &rest initargs)
  "Match Emacs's non-NIL display time for a buffer used to create a window."
  (declare (ignore initargs))
  ;; An :after method with this specializer would replace Lem's own window
  ;; initializer.  Run outside the complete standard initialization instead.
  (let ((initialized-window (call-next-method)))
    (buffer-list-record-display-time (window-buffer initialized-window))
    initialized-window))

(defmethod lem-core::set-window-buffer :after
    (buffer (window lem-core:window))
  "Match Emacs's `set-window-buffer' update of `buffer-display-time'."
  (declare (ignore window))
  (buffer-list-record-display-time buffer))

;; The initial editor window predates the configuration load.
(dolist (window (window-list))
  (buffer-list-record-display-time (window-buffer window)))

(defun buffer-list-buffer-locked-p (buffer)
  "Return true when BUFFER has GNU Emacs's default `all' lock."
  (not (null (variable-value 'buffer-lock-mode :buffer buffer))))

(defun buffer-list-kill-buffer-query (buffer)
  "Refuse every deletion path while BUFFER is locked."
  (when (buffer-list-buffer-locked-p buffer)
    (editor-error "Buffer ~s is locked and cannot be killed"
                  (buffer-name buffer)))
  t)

(defun buffer-list-exit-query ()
  "Refuse editor exit while any live buffer retains an `all' lock."
  (alexandria:when-let
      ((buffer (find-if #'buffer-list-buffer-locked-p (buffer-list))))
    (editor-error "Lem cannot exit because buffer ~s is locked"
                  (buffer-name buffer)))
  t)

(remove-hook (variable-value 'kill-buffer-query-hook :global t)
             'buffer-list-kill-buffer-query)
(add-hook (variable-value 'kill-buffer-query-hook :global t)
          'buffer-list-kill-buffer-query)
(remove-hook *exit-editor-hook* 'buffer-list-exit-query)
;; Query before persistence and process teardown hooks mutate external state.
(add-hook *exit-editor-hook* 'buffer-list-exit-query 100000)

(defparameter *buffer-list-filter-groups*
  '(("org" (:predicate buffer-list-org-buffer-p))
    ("tramp" (:predicate buffer-list-tramp-buffer-p))
    ("emacs" (:predicate buffer-list-emacs-buffer-p))
    ("ediff" (:predicate buffer-list-ediff-buffer-p))
    ("dired" (:predicate buffer-list-dired-buffer-p))
    ("terminal" (:predicate buffer-list-terminal-buffer-p))
    ("help" (:predicate buffer-list-help-buffer-p)))
  "The effective Emacs Ibuffer groups, in their configured first-match order.")

(defvar *buffer-list-saved-filters* nil
  "Session-local Ibuffer filter stacks saved by name.")

(defvar *buffer-list-saved-filter-groups* nil
  "Session-local Ibuffer filter-group sets saved by name.")

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

(defun buffer-list-group-matches-p (group buffer)
  (every (lambda (filter) (buffer-list-filter-match-p filter buffer))
         (rest group)))

(defun buffer-list-group-name (buffer &optional
                                        (groups *buffer-list-filter-groups*))
  "Return BUFFER's first configured group, or \"Default\"."
  (or (loop :for group :in groups
            :when (buffer-list-group-matches-p group buffer)
              :return (first group))
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

(defun buffer-list-grouped-entries
    (&optional (buffers (buffer-list)) (groups *buffer-list-filter-groups*))
  "Group BUFFERS like the configured Ibuffer view, omitting empty groups.

Each nonempty group begins with a distinct heading entry."
  (let ((remaining (copy-list buffers))
        entries)
    (dolist (group groups)
      (multiple-value-bind (matching rest)
          (buffer-list-partition
           remaining
           (lambda (buffer) (buffer-list-group-matches-p group buffer)))
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
   (filter-groups
    :initform (copy-tree *buffer-list-filter-groups*)
    :accessor buffer-list-component-filter-groups)
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
   (tmp-hide-regexps
    :initform nil
    :accessor buffer-list-component-tmp-hide-regexps)
   (tmp-show-regexps
    :initform nil
    :accessor buffer-list-component-tmp-show-regexps)
   (pending-tmp-hide-regexps
    :initform nil
    :accessor buffer-list-component-pending-tmp-hide-regexps)
   (pending-tmp-show-regexps
    :initform nil
    :accessor buffer-list-component-pending-tmp-show-regexps)
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

(define-major-mode buffer-list-diff-mode lem-patch-mode:patch-mode
    (:name "Ibuffer Diff"
     :keymap *buffer-list-diff-mode-keymap*)
  (setf (buffer-read-only-p (current-buffer)) t))

(defmethod lem-vi-mode/core:mode-specific-keymaps
    ((mode buffer-list-diff-mode))
  (list *buffer-list-diff-mode-keymap*))

(define-key *buffer-list-diff-mode-keymap* "q" 'quit-active-window)
(define-key *buffer-list-diff-mode-keymap* "Z Z" 'quit-active-window)
(define-key *buffer-list-diff-mode-keymap* "Z Q" 'quit-active-window)

(defparameter *buffer-list-occur-buffer-name* "*Occur*")
(defconstant +buffer-list-occur-owner+ 'lem-yath-buffer-list-occur)
(defparameter *buffer-list-occur-buffer-character-limit* (* 16 1024 1024))
(defparameter *buffer-list-occur-total-character-limit* (* 64 1024 1024))
(defparameter *buffer-list-occur-match-limit* 10000)
(defparameter *buffer-list-occur-output-character-limit* (* 2 1024 1024))

(defvar *buffer-list-occur-mode-keymap*
  (make-keymap :description '*buffer-list-occur-mode-keymap*))

(defvar *buffer-list-occur-edit-mode-keymap*
  (make-keymap :description '*buffer-list-occur-edit-mode-keymap*))

(define-attribute buffer-list-occur-title-attribute
  (t :foreground :base0D :bold t))

(define-attribute buffer-list-occur-prefix-attribute
  (t :foreground :base0C :bold t))

(define-attribute buffer-list-occur-match-attribute
  (t :foreground :base00 :background :base0D :bold t))

(defstruct buffer-list-occur-match
  start
  end)

(defstruct buffer-list-occur-block
  first-line
  last-line
  matches)

(defstruct buffer-list-occur-source
  buffer
  text
  line-starts
  blocks
  match-count)

(defstruct buffer-list-occur-row-spec
  start
  end
  content-start
  content-end
  source
  line
  block)

(defstruct buffer-list-occur-attribute-spec
  start
  end
  attribute)

(defstruct buffer-list-occur-render-state
  (pieces nil)
  (length 0)
  (rows nil)
  (attributes nil))

(defstruct buffer-list-occur-target
  buffer
  start
  end)

(defstruct buffer-list-occur-line-target
  buffer
  source-start
  source-end
  result-start
  result-end)

(define-major-mode buffer-list-occur-mode nil
    (:name "Occur"
     :keymap *buffer-list-occur-mode-keymap*)
  (setf (buffer-read-only-p (current-buffer)) t
        (variable-value 'line-wrap :buffer (current-buffer)) nil
        (variable-value 'highlight-line :buffer (current-buffer)) t
        (variable-value 'lem/show-paren:enable :buffer (current-buffer)) nil))

(define-major-mode buffer-list-occur-edit-mode buffer-list-occur-mode
    (:name "Occur-Edit"
     :keymap *buffer-list-occur-edit-mode-keymap*)
  (setf (buffer-read-only-p (current-buffer)) nil))

(defmethod lem-vi-mode/core:mode-specific-keymaps
    ((mode buffer-list-occur-mode))
  (list *buffer-list-occur-mode-keymap*))

(defmethod lem-vi-mode/core:mode-specific-keymaps
    ((mode buffer-list-occur-edit-mode))
  (list *buffer-list-occur-edit-mode-keymap*))

(defvar *buffer-list-multi-isearch-mode-keymap*
  (make-keymap :description '*buffer-list-multi-isearch-mode-keymap*))

(define-minor-mode buffer-list-multi-isearch-mode
    (:name "M-Isearch"
     :keymap *buffer-list-multi-isearch-mode-keymap*
     :hide-from-modeline t))

(defstruct buffer-list-multi-isearch-session
  buffers
  start-buffer
  start-point
  forward-function
  backward-function
  regexp-p)

(defvar *buffer-list-multi-isearch-session* nil)

(declaim (ftype function add-search-history))

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

(defparameter *buffer-list-content-filter-character-limit* (* 16 1024 1024)
  "Maximum buffer length inspected by one Ibuffer content filter.")

(defparameter *buffer-list-content-mark-exact-exclusions*
  '("*Completions*" "*Help*" "*Messages*" "*Pp Eval Output*"
    "*CompileLog*" "*Info*" "*Buffer List*" "*Ibuffer*" "*Apropos*")
  "GNU Ibuffer buffer names skipped by an ordinary content-regexp mark.")

(defparameter *buffer-list-content-mark-prefix-exclusions*
  '("*Customize Option: " "*Async Shell Command*"
    "*Shell Command Output*" "*ediff ")
  "GNU Ibuffer buffer-name prefixes skipped by an ordinary content mark.")

(defparameter *buffer-list-starred-name-scanner*
  (cl-ppcre:create-scanner "\\A\\*[^*]+\\*(?:<[0-9]+>)?\\z"))

(defun buffer-list-mode-derived-p (mode parent)
  (alexandria:when-let ((object (ignore-errors (ensure-mode-object mode))))
    (ignore-errors (typep object parent))))

(defun buffer-list-content-regexp-match-p (scanner buffer)
  (and (<= (completion-buffer-size buffer)
           *buffer-list-content-filter-character-limit*)
       (not (null
             (cl-ppcre:scan
              scanner
              (points-to-string (buffer-start-point buffer)
                                (buffer-end-point buffer)))))))

(defun buffer-list-buffer-directory-name (buffer)
  "Return BUFFER's file directory or buffer working directory as a string."
  (let ((directory
          (if (buffer-filename buffer)
              (uiop:pathname-directory-pathname (buffer-filename buffer))
              (ignore-errors (buffer-directory buffer)))))
    (and directory (namestring directory))))

(defun buffer-list-live-process-p (process)
  "Return true when PROCESS is a live UIOP or Lem process object."
  (and process
       (or (ignore-errors (uiop:process-alive-p process))
           (ignore-errors (lem-process:process-alive-p process)))))

(defun buffer-list-compilation-process-buffer-p (buffer)
  "Return true when BUFFER owns the active configured compilation process."
  (let ((session
          (ignore-errors
            (buffer-value buffer :lem-yath-compilation-session))))
    (and session
         (fboundp 'compilation-process-alive-p)
         (ignore-errors
           (funcall (symbol-function 'compilation-process-alive-p) session)))))

(defun buffer-list-process-buffer-p (buffer)
  "Return true when BUFFER owns a process visible to Lem."
  (or (buffer-list-live-process-p
       (ignore-errors (buffer-value buffer 'process)))
      (buffer-list-live-process-p
       (ignore-errors (lem-shell-mode::buffer-process buffer)))
      (buffer-list-compilation-process-buffer-p buffer)
      (ignore-errors
        (with-current-buffer buffer
          (not (null
                (lem-terminal/terminal-mode::get-current-terminal)))))))

(defun buffer-list-content-mark-excluded-p (buffer)
  "Return true when GNU Ibuffer normally skips BUFFER's content."
  (let ((name (buffer-name buffer)))
    (or (buffer-list-dired-buffer-p buffer)
        (member name *buffer-list-content-mark-exact-exclusions*
                :test #'string=)
        (some (lambda (prefix)
                (alexandria:starts-with-subseq prefix name))
              *buffer-list-content-mark-prefix-exclusions*))))

(defun buffer-list-filter-match-p (filter buffer)
  (ecase (first filter)
    (:predicate (funcall (second filter) buffer))
    (:or
     (some (lambda (operand)
             (buffer-list-filter-match-p operand buffer))
           (rest filter)))
    (:and
     (every (lambda (operand)
              (buffer-list-filter-match-p operand buffer))
            (rest filter)))
    (:saved
     (let ((saved (assoc (second filter) *buffer-list-saved-filters*
                         :test #'string=)))
       (unless saved
         (editor-error "Unknown saved Ibuffer filter ~a" (second filter)))
       (every (lambda (operand)
                (buffer-list-filter-match-p operand buffer))
              (rest saved))))
    (:process (buffer-list-process-buffer-p buffer))
    (:modified (buffer-modified-p buffer))
    (:visiting-file (buffer-filename buffer))
    (:exact-mode
     (member (buffer-major-mode buffer) (second filter) :test #'eq))
    (:derived-mode
     (some (lambda (parent)
             (buffer-list-mode-derived-p (buffer-major-mode buffer) parent))
           (second filter)))
    (:mode
     (buffer-list-regexp-match-p
      (second filter) (symbol-name (buffer-major-mode buffer))))
    (:starred-name
     (not (null (cl-ppcre:scan *buffer-list-starred-name-scanner*
                               (buffer-name buffer)))))
    (:name
     (buffer-list-regexp-match-p (second filter) (buffer-name buffer)))
    (:filename
     (buffer-list-regexp-match-p (second filter) (buffer-filename buffer)))
    (:directory
     (buffer-list-regexp-match-p
      (second filter) (buffer-list-buffer-directory-name buffer)))
    (:basename
     (alexandria:when-let ((filename (buffer-filename buffer)))
       (buffer-list-regexp-match-p
        (second filter) (file-namestring filename))))
    (:extension
     (alexandria:when-let ((filename (buffer-filename buffer)))
       (buffer-list-regexp-match-p
        (second filter) (or (pathname-type filename) ""))))
    (:size-lt (< (completion-buffer-size buffer) (second filter)))
    (:size-gt (> (completion-buffer-size buffer) (second filter)))
    (:content (buffer-list-content-regexp-match-p (third filter) buffer))
    (:not (not (buffer-list-filter-match-p (second filter) buffer)))))

(defun buffer-list-matches-any-regexp-p (patterns buffer)
  (some (lambda (pattern)
          (buffer-list-regexp-match-p pattern (buffer-name buffer)))
        patterns))

(defun buffer-list-active-filters-match-p (component buffer)
  ;; GNU Ibuffer's temporary show list takes precedence over both its hide
  ;; list and ordinary filters.  Pending patterns become active only on `gr'.
  (or (buffer-list-matches-any-regexp-p
       (buffer-list-component-tmp-show-regexps component) buffer)
      (and
       (not (buffer-list-matches-any-regexp-p
             (buffer-list-component-tmp-hide-regexps component) buffer))
       (every (lambda (filter) (buffer-list-filter-match-p filter buffer))
              (buffer-list-component-filters component)))))

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
  "Return Ibuffer's modified, read-only, and lock status fields."
  (format nil "~c~c~c"
          (if (buffer-modified-p buffer) #\* #\Space)
          (if (buffer-read-only-p buffer) #\% #\Space)
          (if (buffer-list-buffer-locked-p buffer) #\L #\Space)))

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

(defun buffer-list-snapshot-buffers (component)
  (loop :for item :in (buffer-list-component-all-items component)
        :for entry := (buffer-list-item-entry item)
        :for buffer := (unless (buffer-list-entry-heading-p entry)
                         (buffer-list-entry-buffer entry))
        :when (and buffer (eq buffer (get-buffer (buffer-name buffer))))
          :collect buffer))

(defun buffer-list-mode-label (mode)
  (if (symbol-package mode)
      (format nil "~a::~a"
              (package-name (symbol-package mode))
              (symbol-name mode))
      (symbol-name mode)))

(defun buffer-list-mode-candidates (modes)
  (sort
   (mapcar (lambda (mode) (cons (buffer-list-mode-label mode) mode))
           (remove-duplicates modes :test #'eq))
   #'string-lessp :key #'car))

(defun buffer-list-snapshot-derived-modes (component)
  (let ((registered (major-modes)))
    (remove-duplicates
     (loop :for buffer :in (buffer-list-snapshot-buffers component)
           :for object := (ignore-errors
                            (ensure-mode-object (buffer-major-mode buffer)))
           :when object
             :append
             (loop :for class :in
                     (c2mop:class-precedence-list (class-of object))
                   :for name := (class-name class)
                   :when (and (symbolp name)
                              (member name registered :test #'eq))
                     :collect name))
     :test #'eq)))

(defun buffer-list-comma-parts (input)
  (loop :with start := 0
        :for comma := (position #\, input :start start)
        :collect (string-trim '(#\Space #\Tab)
                              (subseq input start comma))
        :while comma
        :do (setf start (1+ comma))))

(defun buffer-list-mode-choices (input candidates)
  (let ((parts (buffer-list-comma-parts input)))
    (when (and parts (every (lambda (part) (plusp (length part))) parts))
      (let ((modes
              (mapcar (lambda (part)
                        (cdr (assoc part candidates :test #'string=)))
                      parts)))
        (when (every #'identity modes)
          (remove-duplicates modes :test #'eq))))))

(defun buffer-list-mode-completions (input candidates)
  (let* ((comma (position #\, input :from-end t))
         (prefix (if comma (subseq input 0 (1+ comma)) ""))
         (fragment (string-trim '(#\Space #\Tab)
                                (if comma (subseq input (1+ comma)) input))))
    (mapcar (lambda (candidate)
              (concatenate 'string prefix (car candidate)))
            (prescient-filter fragment candidates :key #'car))))

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

(defun buffer-list-unmark-backward (component)
  (lem/multi-column-list::multi-column-list/up)
  (when (buffer-list-set-item-mark
         component (buffer-list-current-item component) :none)
    (lem/multi-column-list:update component)))

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

(defun buffer-list-mark-matching (component predicate)
  (let ((count 0))
    (dolist (item (buffer-list-current-view-items component))
      (let ((entry (buffer-list-item-entry item)))
        (when (and (not (buffer-list-entry-heading-p entry))
                   (funcall predicate (buffer-list-entry-buffer entry)))
          (buffer-list-set-item-mark component item :marked)
          (incf count))))
    (lem/multi-column-list:update component)
    (message "Marked ~d buffers" count)))

(defun buffer-list-special-buffer-p (buffer)
  (let ((name (buffer-name buffer)))
    (and (> (length name) 2)
         (char= #\* (char name 0))
         (char= #\* (char name (1- (length name)))))))

(defun buffer-list-unsaved-buffer-p (buffer)
  (and (buffer-filename buffer) (buffer-modified-p buffer)))

(defun buffer-list-dissociated-buffer-p (buffer)
  (alexandria:when-let ((filename (buffer-filename buffer)))
    (null (ignore-errors (uiop:probe-file* filename)))))

(defun buffer-list-compressed-file-buffer-p (buffer)
  (alexandria:when-let ((filename (buffer-filename buffer)))
    (buffer-list-regexp-match-p
     "\\.(?:arj|bgz|bz2|gz|lzh|taz|tgz|xz|zip|z)$"
     (namestring filename))))

(defun buffer-list-old-buffer-p (buffer &optional (now (get-universal-time)))
  "Return true when BUFFER was last displayed over `ibuffer-old-time' hours ago.

Like GNU Ibuffer, a never-displayed buffer is not old and the age comparison is
strict: a buffer exactly at the threshold is not marked."
  (alexandria:when-let ((display-time
                         (buffer-list-buffer-display-time buffer)))
    (> (- now display-time)
       (* 60 60 (variable-value 'ibuffer-old-time :global)))))

(define-command lem-yath-buffer-list-mark-modified () ()
  (buffer-list-mark-matching
   (lem/multi-column-list::current-multi-column-list) #'buffer-modified-p))

(define-command lem-yath-buffer-list-mark-unsaved () ()
  (buffer-list-mark-matching
   (lem/multi-column-list::current-multi-column-list)
   #'buffer-list-unsaved-buffer-p))

(define-command lem-yath-buffer-list-mark-special () ()
  (buffer-list-mark-matching
   (lem/multi-column-list::current-multi-column-list)
   #'buffer-list-special-buffer-p))

(define-command lem-yath-buffer-list-mark-read-only () ()
  (buffer-list-mark-matching
   (lem/multi-column-list::current-multi-column-list) #'buffer-read-only-p))

(define-command lem-yath-buffer-list-mark-locked () ()
  (buffer-list-mark-matching
   (lem/multi-column-list::current-multi-column-list)
   #'buffer-list-buffer-locked-p))

(define-command lem-yath-buffer-list-mark-dired () ()
  (buffer-list-mark-matching
   (lem/multi-column-list::current-multi-column-list)
   #'buffer-list-dired-buffer-p))

(define-command lem-yath-buffer-list-mark-dissociated () ()
  (buffer-list-mark-matching
   (lem/multi-column-list::current-multi-column-list)
   #'buffer-list-dissociated-buffer-p))

(define-command lem-yath-buffer-list-mark-help () ()
  (buffer-list-mark-matching
   (lem/multi-column-list::current-multi-column-list)
   #'buffer-list-help-buffer-p))

(define-command lem-yath-buffer-list-mark-compressed-file () ()
  (buffer-list-mark-matching
   (lem/multi-column-list::current-multi-column-list)
   #'buffer-list-compressed-file-buffer-p))

(define-command lem-yath-buffer-list-mark-old () ()
  "Mark visible buffers not displayed in `ibuffer-old-time' hours."
  (buffer-list-mark-matching
   (lem/multi-column-list::current-multi-column-list)
   #'buffer-list-old-buffer-p))

(defun buffer-list-compile-mark-regexp (pattern)
  "Compile PATTERN before any Ibuffer mark is changed."
  (handler-case
      (cl-ppcre:create-scanner pattern :case-insensitive-mode t)
    (error () (editor-error "Invalid Ibuffer mark regexp"))))

(defun buffer-list-mark-by-regexp (component scanner value-function)
  "Mark visible buffers whose VALUE-FUNCTION result matches SCANNER."
  (buffer-list-mark-matching
   component
   (lambda (buffer)
     (alexandria:when-let ((value (funcall value-function buffer)))
       (not (null (cl-ppcre:scan scanner value)))))))

(define-command lem-yath-buffer-list-mark-by-name-regexp () ()
  "Mark visible buffers whose names match a regexp."
  (let* ((pattern (prompt-for-string "Mark by name (regexp): "))
         (scanner (buffer-list-compile-mark-regexp pattern)))
    (buffer-list-mark-by-regexp
     (lem/multi-column-list::current-multi-column-list)
     scanner #'buffer-name)))

(define-command lem-yath-buffer-list-mark-by-mode-regexp () ()
  "Mark visible buffers whose displayed major-mode names match a regexp."
  (let* ((pattern (prompt-for-string "Mark by major mode (regexp): "))
         (scanner (buffer-list-compile-mark-regexp pattern)))
    (buffer-list-mark-by-regexp
     (lem/multi-column-list::current-multi-column-list)
     scanner
     (lambda (buffer) (mode-name (buffer-major-mode buffer))))))

(define-command lem-yath-buffer-list-mark-by-file-regexp () ()
  "Mark visible file buffers whose full names match a regexp."
  (let* ((pattern (prompt-for-string "Mark by file name (regexp): "))
         (scanner (buffer-list-compile-mark-regexp pattern)))
    (buffer-list-mark-by-regexp
     (lem/multi-column-list::current-multi-column-list)
     scanner
     (lambda (buffer)
       (alexandria:when-let ((filename (buffer-filename buffer)))
         (namestring filename))))))

(define-command lem-yath-buffer-list-mark-by-content-regexp
    (all-buffers) (:universal-nil)
  "Mark visible buffers whose bounded contents match a regexp.
With a prefix, include buffers GNU Ibuffer normally excludes."
  (let* ((pattern (prompt-for-string "Mark by content (regexp): "))
         (scanner (buffer-list-compile-mark-regexp pattern)))
    (buffer-list-mark-matching
     (lem/multi-column-list::current-multi-column-list)
     (lambda (buffer)
       (and (or all-buffers
                (not (buffer-list-content-mark-excluded-p buffer)))
            (buffer-list-content-regexp-match-p scanner buffer))))))

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

(define-command lem-yath-buffer-list-unmark-backward () ()
  (buffer-list-unmark-backward
   (lem/multi-column-list::current-multi-column-list)))

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

(define-command lem-yath-buffer-list-start-directory-filter () ()
  (buffer-list-start-input-filter :directory "directory name"))

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
    (:predicate
     (string-downcase (symbol-name (second filter))))
    (:or
     (format nil "or(~{~a~^,~})"
             (mapcar #'buffer-list-filter-description (rest filter))))
    (:and
     (format nil "and(~{~a~^,~})"
             (mapcar #'buffer-list-filter-description (rest filter))))
    (:saved (format nil "saved=~a" (second filter)))
    (:process "process")
    (:modified "modified")
    (:visiting-file "visiting-file")
    (:exact-mode
     (format nil "mode-is=~{~a~^,~}"
             (mapcar #'buffer-list-mode-label (second filter))))
    (:derived-mode
     (format nil "derived-mode=~{~a~^,~}"
             (mapcar #'buffer-list-mode-label (second filter))))
    (:mode (format nil "mode=~a" (second filter)))
    (:starred-name "starred-name")
    (:name (format nil "name=~a" (second filter)))
    (:filename (format nil "filename=~a" (second filter)))
    (:directory (format nil "directory=~a" (second filter)))
    (:basename (format nil "basename=~a" (second filter)))
    (:extension (format nil "extension=~a" (second filter)))
    (:size-lt (format nil "size<~d" (second filter)))
    (:size-gt (format nil "size>~d" (second filter)))
    (:content (format nil "content=~a" (second filter)))
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

(defun buffer-list-prompt-mode-filter (component kind prompt modes)
  (let* ((candidates (buffer-list-mode-candidates modes))
         (current (buffer-list-require-current-buffer component))
         (default (rassoc (buffer-major-mode current) candidates :test #'eq)))
    (unless candidates
      (editor-error "No Ibuffer modes are available"))
    (let* ((choice
             (prompt-for-string
              (if default
                  (format nil "~a (default ~a): " prompt (car default))
                  (format nil "~a: " prompt))
              :completion-function
              (lambda (input)
                (let ((completions
                        (buffer-list-mode-completions input candidates)))
                  (if (and default (zerop (length input)))
                      (cons (car default)
                            (remove (car default) completions :test #'string=))
                      completions)))
              :test-function
              (lambda (input)
                (or (and default (zerop (length input)))
                    (buffer-list-mode-choices input candidates)))))
           (selected
             (if (zerop (length choice))
                 (and default (list (cdr default)))
                 (buffer-list-mode-choices choice candidates))))
      (unless selected
        (editor-error "No matching Ibuffer mode"))
      (buffer-list-push-filter component (list kind selected)))))

(define-command lem-yath-buffer-list-filter-by-mode () ()
  (let ((component (lem/multi-column-list::current-multi-column-list)))
    (buffer-list-prompt-mode-filter
     component :exact-mode "Filter by major mode" (major-modes))))

(define-command lem-yath-buffer-list-filter-by-derived-mode () ()
  (let ((component (lem/multi-column-list::current-multi-column-list)))
    (buffer-list-prompt-mode-filter
     component :derived-mode "Filter by derived mode"
     (buffer-list-snapshot-derived-modes component))))

(define-command lem-yath-buffer-list-mark-by-mode () ()
  "Mark visible buffers whose major mode equals the selected used mode."
  (let* ((component (lem/multi-column-list::current-multi-column-list))
         (modes (remove-duplicates
                 (mapcar #'buffer-major-mode
                         (buffer-list-snapshot-buffers component))
                 :test #'eq))
         (candidates (buffer-list-mode-candidates modes))
         (current (buffer-list-require-current-buffer component))
         (default (rassoc (buffer-major-mode current) candidates :test #'eq)))
    (unless candidates
      (editor-error "No Ibuffer modes are available"))
    (let* ((choice
             (prompt-for-string
              (if default
                  (format nil "Mark by major mode (default ~a): " (car default))
                  "Mark by major mode: ")
              :completion-function
              (lambda (input)
                (buffer-list-mode-completions input candidates))
              :test-function
              (lambda (input)
                (or (and default (zerop (length input)))
                    (assoc input candidates :test #'string=)))))
           (mode
             (if (zerop (length choice))
                 (and default (cdr default))
                 (cdr (assoc choice candidates :test #'string=)))))
      (unless mode
        (editor-error "No matching Ibuffer mode"))
      (buffer-list-mark-matching
       component
       (lambda (buffer) (eq mode (buffer-major-mode buffer)))))))

(define-command lem-yath-buffer-list-filter-starred-name () ()
  (buffer-list-push-filter
   (lem/multi-column-list::current-multi-column-list) '(:starred-name)))

(define-command lem-yath-buffer-list-filter-process () ()
  (buffer-list-push-filter
   (lem/multi-column-list::current-multi-column-list) '(:process)))

(define-command lem-yath-buffer-list-filter-size-lt () ()
  (buffer-list-push-filter
   (lem/multi-column-list::current-multi-column-list)
   (list :size-lt (prompt-for-integer "Filter by size less than: "))))

(define-command lem-yath-buffer-list-filter-size-gt () ()
  (buffer-list-push-filter
   (lem/multi-column-list::current-multi-column-list)
   (list :size-gt (prompt-for-integer "Filter by size greater than: "))))

(define-command lem-yath-buffer-list-filter-content () ()
  (let* ((pattern (prompt-for-string "Filter by content (regexp): "))
         (scanner
           (handler-case
               (cl-ppcre:create-scanner pattern :case-insensitive-mode t)
             (error () (editor-error "Invalid Ibuffer content regexp")))))
    (buffer-list-push-filter
     (lem/multi-column-list::current-multi-column-list)
     (list :content pattern scanner))))

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

(defun buffer-list-compound-operands (operator filter)
  "Return FILTER's operands, flattening it when it already uses OPERATOR."
  (if (eq operator (first filter))
      (rest filter)
      (list filter)))

(defun buffer-list-compose-filters (component operator)
  "Replace COMPONENT's top two filters with a flattened OPERATOR filter."
  (let ((filters (buffer-list-component-filters component)))
    (when (< (length filters) 2)
      (editor-error "Need two Ibuffer filters to ~(~a~)"
                    (symbol-name operator)))
    (let ((first (first filters))
          (second (second filters)))
      (setf (buffer-list-component-filters component)
            (cons (cons operator
                        (append (buffer-list-compound-operands operator first)
                                (buffer-list-compound-operands operator second)))
                  (cddr filters))))
    (buffer-list-refresh-filters component)))

(define-command lem-yath-buffer-list-or-filter () ()
  (buffer-list-compose-filters
   (lem/multi-column-list::current-multi-column-list) :or))

(define-command lem-yath-buffer-list-and-filter () ()
  (buffer-list-compose-filters
   (lem/multi-column-list::current-multi-column-list) :and))

(define-command lem-yath-buffer-list-exchange-filters () ()
  (let* ((component (lem/multi-column-list::current-multi-column-list))
         (filters (buffer-list-component-filters component)))
    (when (< (length filters) 2)
      (editor-error "Need two Ibuffer filters to exchange"))
    (setf (buffer-list-component-filters component)
          (list* (second filters) (first filters) (cddr filters)))
    (buffer-list-refresh-filters component)))

(defun buffer-list-saved-filter (name)
  (assoc name *buffer-list-saved-filters* :test #'string=))

(defun buffer-list-read-saved-filter-name (prompt)
  (unless *buffer-list-saved-filters*
    (editor-error "No saved Ibuffer filters"))
  (let ((names (mapcar #'car *buffer-list-saved-filters*)))
    (prompt-for-string
     prompt
     :completion-function
     (lambda (input) (prescient-filter input names))
     :test-function
     (lambda (input) (member input names :test #'string=)))))

(define-command lem-yath-buffer-list-save-filters () ()
  (let* ((component (lem/multi-column-list::current-multi-column-list))
         (filters (buffer-list-component-filters component)))
    (unless filters
      (editor-error "No Ibuffer filters currently in effect"))
    (let* ((name (prompt-for-string "Save current filters as: "))
           (saved (buffer-list-saved-filter name))
           (snapshot (copy-tree filters)))
      (when (some (lambda (filter)
                    (buffer-list-filter-references-saved-p filter name))
                  snapshot)
        (editor-error "Saving Ibuffer filters as ~a would create a cycle"
                      name))
      (if saved
          (setf (cdr saved) snapshot)
          (push (cons name snapshot) *buffer-list-saved-filters*))
      (message "Saved Ibuffer filters as ~a" name))))

(define-command lem-yath-buffer-list-add-saved-filters () ()
  (let* ((component (lem/multi-column-list::current-multi-column-list))
         (name (buffer-list-read-saved-filter-name "Add saved filters: ")))
    (push (list :saved name) (buffer-list-component-filters component))
    (buffer-list-refresh-filters component)))

(define-command lem-yath-buffer-list-switch-to-saved-filters () ()
  (let* ((component (lem/multi-column-list::current-multi-column-list))
         (name (buffer-list-read-saved-filter-name "Switch to saved filters: ")))
    (setf (buffer-list-component-filters component) (list (list :saved name)))
    (buffer-list-refresh-filters component)))

(defun buffer-list-filter-references-saved-p (filter name &optional visited)
  "Return true when FILTER directly or transitively references saved NAME."
  (case (first filter)
    (:saved
     (let ((reference (second filter)))
       (or (string= name reference)
           (unless (member reference visited :test #'string=)
             (alexandria:when-let ((saved (buffer-list-saved-filter reference)))
               (some (lambda (operand)
                       (buffer-list-filter-references-saved-p
                        operand name (cons reference visited)))
                     (rest saved)))))))
    ((:or :and)
     (some (lambda (operand)
             (buffer-list-filter-references-saved-p operand name visited))
           (rest filter)))
    (:not (buffer-list-filter-references-saved-p
           (second filter) name visited))
    (otherwise nil)))

(define-command lem-yath-buffer-list-delete-saved-filters () ()
  (let* ((component (lem/multi-column-list::current-multi-column-list))
         (name (buffer-list-read-saved-filter-name "Delete saved filters: ")))
    (let ((active-reference-p
            (some (lambda (filter)
                    (buffer-list-filter-references-saved-p filter name))
                  (buffer-list-component-filters component)))
          (group-reference-p
            (some (lambda (group)
                    (some (lambda (filter)
                            (buffer-list-filter-references-saved-p filter name))
                          (rest group)))
                  (buffer-list-component-filter-groups component))))
      (setf *buffer-list-saved-filters*
            (remove name *buffer-list-saved-filters*
                    :key #'car :test #'string=))
      ;; GNU Ibuffer disables an active stack when its saved reference becomes
      ;; invalid.  Clear before refreshing so rendering never observes a
      ;; dangling definition.
      (when active-reference-p
        (setf (buffer-list-component-filters component) nil))
      (when group-reference-p
        (setf (buffer-list-component-filter-groups component) nil
              (buffer-list-component-hidden-groups component) nil))
      (if group-reference-p
          (buffer-list-regroup component)
          (buffer-list-refresh-filters component)))))

(define-command lem-yath-buffer-list-decompose-filter () ()
  (let* ((component (lem/multi-column-list::current-multi-column-list))
         (filters (buffer-list-component-filters component)))
    (unless filters
      (editor-error "No Ibuffer filters in effect"))
    (let* ((filter (first filters))
           (tail (rest filters))
           (replacement
             (case (first filter)
               ((:or :and) (rest filter))
               (:not (list (second filter)))
               (:saved
                (let ((saved (buffer-list-saved-filter (second filter))))
                  (unless saved
                    (setf (buffer-list-component-filters component) nil)
                    (editor-error "Unknown saved Ibuffer filter ~a"
                                  (second filter)))
                  (copy-tree (rest saved))))
               (otherwise
                (editor-error "Ibuffer filter type ~(~a~) is not compound"
                              (symbol-name (first filter)))))))
      (setf (buffer-list-component-filters component)
            (append replacement tail))
      (buffer-list-refresh-filters component))))

(defun buffer-list-filter-group-names (component)
  (mapcar #'first (buffer-list-component-filter-groups component)))

(defun buffer-list-read-filter-group-name (component prompt)
  (let ((names (buffer-list-filter-group-names component)))
    (unless names
      (editor-error "No Ibuffer filter groups are active"))
    (prompt-for-string
     prompt
     :completion-function (lambda (input) (prescient-filter input names))
     :test-function (lambda (input) (member input names :test #'string=)))))

(defun buffer-list-remove-first-named-group (name groups)
  (let ((removed-p nil))
    (remove-if (lambda (group)
                 (and (not removed-p)
                      (string= name (first group))
                      (setf removed-p t)))
               groups)))

(define-command lem-yath-buffer-list-filters-to-filter-group () ()
  (let* ((component (lem/multi-column-list::current-multi-column-list))
         (filters (buffer-list-component-filters component)))
    (unless filters
      (editor-error "No Ibuffer filters in effect"))
    (let ((name (prompt-for-string "Name for filtering group: ")))
      (push (cons name (copy-tree filters))
            (buffer-list-component-filter-groups component))
      (setf (buffer-list-component-filters component) nil)
      (buffer-list-regroup component)
      (message "Made Ibuffer filter group ~a" name))))

(define-command lem-yath-buffer-list-pop-filter-group () ()
  (let ((component (lem/multi-column-list::current-multi-column-list)))
    (unless (buffer-list-component-filter-groups component)
      (editor-error "No Ibuffer filter groups are active"))
    (pop (buffer-list-component-filter-groups component))
    (buffer-list-regroup component)))

(define-command lem-yath-buffer-list-decompose-filter-group () ()
  (let* ((component (lem/multi-column-list::current-multi-column-list))
         (name (buffer-list-read-filter-group-name
                component "Decompose filter group: "))
         (group (find name (buffer-list-component-filter-groups component)
                      :key #'first :test #'string=)))
    (setf (buffer-list-component-filter-groups component)
          (buffer-list-remove-first-named-group
           name (buffer-list-component-filter-groups component))
          (buffer-list-component-filters component) (copy-tree (rest group)))
    (buffer-list-regroup component)
    (buffer-list-refresh-filters component)))

(define-command lem-yath-buffer-list-clear-filter-groups () ()
  (let ((component (lem/multi-column-list::current-multi-column-list)))
    (setf (buffer-list-component-filter-groups component) nil
          (buffer-list-component-hidden-groups component) nil)
    (buffer-list-regroup component)
    (message "Ibuffer filter groups cleared")))

(defun buffer-list-saved-filter-group-set (name)
  (assoc name *buffer-list-saved-filter-groups* :test #'string=))

(defun buffer-list-read-saved-filter-group-name (prompt)
  (unless *buffer-list-saved-filter-groups*
    (editor-error "No saved Ibuffer filter groups"))
  (let ((names (mapcar #'car *buffer-list-saved-filter-groups*)))
    (if (and (string= prompt "Switch to saved filter groups: ")
             (null (rest names)))
        (first names)
        (prompt-for-string
         prompt
         :completion-function (lambda (input) (prescient-filter input names))
         :test-function
         (lambda (input) (member input names :test #'string=))))))

(define-command lem-yath-buffer-list-save-filter-groups () ()
  (let* ((component (lem/multi-column-list::current-multi-column-list))
         (groups (buffer-list-component-filter-groups component)))
    (unless groups
      (editor-error "No Ibuffer filter groups are active"))
    (let* ((name (prompt-for-string "Save current filter groups as: "))
           (saved (buffer-list-saved-filter-group-set name))
           (snapshot (copy-tree groups)))
      (if saved
          (setf (cdr saved) snapshot)
          (push (cons name snapshot) *buffer-list-saved-filter-groups*))
      (message "Saved Ibuffer filter groups as ~a" name))))

(define-command lem-yath-buffer-list-switch-to-saved-filter-groups () ()
  (let* ((component (lem/multi-column-list::current-multi-column-list))
         (name (buffer-list-read-saved-filter-group-name
                "Switch to saved filter groups: "))
         (saved (buffer-list-saved-filter-group-set name)))
    (setf (buffer-list-component-filter-groups component) (copy-tree (rest saved))
          (buffer-list-component-hidden-groups component) nil)
    (buffer-list-regroup component)
    (message "Switched to Ibuffer filter groups ~a" name)))

(define-command lem-yath-buffer-list-delete-saved-filter-groups () ()
  (let ((name (buffer-list-read-saved-filter-group-name
               "Delete saved filter groups: ")))
    (setf *buffer-list-saved-filter-groups*
          (remove name *buffer-list-saved-filter-groups*
                  :key #'car :test #'string=))
    (message "Deleted saved Ibuffer filter groups ~a" name)))

(defun buffer-list-action-items (component)
  (let ((marked
          (remove-if
           (lambda (item)
             (or (not (lem/multi-column-list::multi-column-list-item-checked-p
                       item))
                 (gethash item
                          (buffer-list-component-deletion-items component))
                 (buffer-list-entry-heading-p (buffer-list-item-entry item))))
           (lem/multi-column-list::multi-column-list-items component))))
    (or marked
        (alexandria:when-let ((item (buffer-list-current-item component)))
          (unless (buffer-list-entry-heading-p (buffer-list-item-entry item))
            (buffer-list-set-item-mark component item :marked)
            (lem/multi-column-list:update component)
            (list item))))))

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

(defun buffer-list-validate-temp-visibility-regexp (pattern)
  (handler-case
      (progn
        (cl-ppcre:create-scanner pattern :case-insensitive-mode t)
        pattern)
    (error ()
      (editor-error "Invalid Ibuffer visibility regexp"))))

(defun buffer-list-read-temp-visibility-regexp (component prompt)
  (let* ((buffer (buffer-list-require-current-buffer component))
         (pattern
           (prompt-for-string
            prompt
            :initial-value
            (cl-ppcre:quote-meta-chars (buffer-name buffer)))))
    (buffer-list-validate-temp-visibility-regexp pattern)))

(define-command lem-yath-buffer-list-add-to-tmp-hide () ()
  "Stage a buffer-name regexp to hide on the next `gr' update."
  (let ((component (lem/multi-column-list::current-multi-column-list)))
    (push (buffer-list-read-temp-visibility-regexp
           component "Never show buffers matching: ")
          (buffer-list-component-pending-tmp-hide-regexps component))))

(define-command lem-yath-buffer-list-add-to-tmp-show () ()
  "Stage a buffer-name regexp to force visible on the next `gr' update."
  (let ((component (lem/multi-column-list::current-multi-column-list)))
    (push (buffer-list-read-temp-visibility-regexp
           component "Always show buffers matching: ")
          (buffer-list-component-pending-tmp-show-regexps component))))

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

(defun buffer-list-jump-to-buffer (component name)
  (let* ((item
           (find name (buffer-list-component-all-items component)
                 :key (lambda (candidate)
                        (let ((entry (buffer-list-item-entry candidate)))
                          (unless (buffer-list-entry-heading-p entry)
                            (buffer-name (buffer-list-entry-buffer entry)))))
                 :test #'string=))
         (entry (and item (buffer-list-item-entry item)))
         (buffer (and entry (buffer-list-entry-buffer entry))))
    (unless (and buffer
                 (eq buffer (get-buffer name))
                 (buffer-list-active-filters-match-p component buffer))
      (editor-error "No buffer with name ~a" name))
    (setf (buffer-list-component-hidden-groups component)
          (delete (buffer-list-entry-group entry)
                  (buffer-list-component-hidden-groups component)
                  :test #'string=)
          (lem/multi-column-list::multi-column-list-search-string component) "")
    (buffer-list-reset-visible-items component)
    (lem/multi-column-list:update component)
    (unless (buffer-list-focus-buffer component buffer)
      (editor-error "No buffer with name ~a" name))
    buffer))

(define-command lem-yath-buffer-list-jump-to-buffer () ()
  (let* ((component (lem/multi-column-list::current-multi-column-list))
         (names (mapcar #'buffer-name
                        (buffer-list-snapshot-buffers component)))
         (name
           (prompt-for-string
            "Jump to buffer: "
            :completion-function
            (lambda (input) (prescient-filter input names))
            :test-function
            (lambda (input) (member input names :test #'string=)))))
    (unless (zerop (length name))
      (buffer-list-jump-to-buffer component name))))

(define-command lem-yath-buffer-list-visit-other-window () ()
  (let* ((component (lem/multi-column-list::current-multi-column-list))
         (buffer (buffer-list-require-current-buffer component)))
    (lem/multi-column-list:quit component)
    (switch-to-window (pop-to-buffer buffer))))

(defun buffer-list-source-window (component)
  (let* ((popup-menu
           (lem/multi-column-list::multi-column-list-popup-menu component))
         (popup-window
           (lem/popup-menu::popup-menu-window popup-menu))
         (source-window (window-parent popup-window)))
    (unless (and source-window (not (deleted-window-p source-window)))
      (editor-error "Ibuffer source window is no longer available"))
    source-window))

(define-command lem-yath-buffer-list-visit-other-window-noselect () ()
  (let* ((component (lem/multi-column-list::current-multi-column-list))
         (buffer (buffer-list-require-current-buffer component))
         (source-window (buffer-list-source-window component)))
    ;; GNU Ibuffer's C-o leaves Ibuffer selected.  Lem's Ibuffer is a floating
    ;; chooser, so display through its ordinary source window and let
    ;; WITH-CURRENT-WINDOW restore focus to the chooser.
    (with-current-window source-window
      (pop-to-buffer buffer))))

(define-command lem-yath-buffer-list-visit-one-window () ()
  (let* ((component (lem/multi-column-list::current-multi-column-list))
         (buffer (buffer-list-require-current-buffer component)))
    (lem/multi-column-list:quit component)
    (switch-to-buffer buffer)
    (delete-other-windows)))

(defun buffer-list-view-buffers (component)
  "Return GNU Ibuffer's ordinary marked buffers, or the current buffer.

The lookup uses the filtered snapshot rather than only expanded groups, so a
mark inside a collapsed group still participates.  Deletion marks never do."
  (or (loop :for item :in (buffer-list-component-all-items component)
            :for entry := (buffer-list-item-entry item)
            :for buffer := (unless (buffer-list-entry-heading-p entry)
                             (buffer-list-entry-buffer entry))
            :when (and buffer
                       (buffer-list-ordinary-marked-item-p component item)
                       (buffer-list-active-filters-match-p component buffer)
                       (eq buffer (get-buffer (buffer-name buffer))))
              :collect buffer)
      (list (buffer-list-require-current-buffer component))))

(defun buffer-list-view-frame-dimension (orientation)
  (ecase orientation
    (:vertically (lem-core::max-window-height (current-frame)))
    (:horizontally (lem-core::max-window-width (current-frame)))))

(defun buffer-list-check-view-capacity (orientation count)
  (let ((dimension (buffer-list-view-frame-dimension orientation)))
    (when (< dimension (* 2 count))
      (editor-error "Cannot view ~d buffers in ~d terminal cells"
                    count dimension))
    (floor dimension count)))

(defun buffer-list-view (component orientation)
  (let* ((buffers (buffer-list-view-buffers component))
         (size (buffer-list-check-view-capacity
                orientation (length buffers))))
    (lem/multi-column-list:quit component)
    (delete-other-windows)
    (switch-to-buffer (first buffers))
    (dolist (buffer (rest buffers))
      (let ((window (current-window)))
        (ecase orientation
          (:vertically (split-window-vertically window :height size))
          (:horizontally (split-window-horizontally window :width size)))
        (switch-to-window (get-next-window window))
        (switch-to-buffer buffer)))
    (balance-windows)))

(define-command lem-yath-buffer-list-view () ()
  (buffer-list-view
   (lem/multi-column-list::current-multi-column-list) :vertically))

(define-command lem-yath-buffer-list-view-horizontally () ()
  (buffer-list-view
   (lem/multi-column-list::current-multi-column-list) :horizontally))

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
      (buffer-list-focus-index component index))))

(defun buffer-list-focus-index (component index)
  (let ((items (lem/multi-column-list::multi-column-list-items component)))
    (when items
      (lem/multi-column-list::multi-column-list/first)
      (dotimes (_ (min index (1- (length items))))
        (lem/multi-column-list::multi-column-list/down))
      t)))

(defun buffer-list-regroup (component)
  "Rebuild COMPONENT under its current filter groups, preserving row state."
  (let ((focused-buffer (buffer-list-current-buffer component))
        (marks (buffer-list-record-marks component))
        (buffers (buffer-list-snapshot-buffers component)))
    (clrhash (buffer-list-component-deletion-items component))
    (setf (buffer-list-component-hidden-groups component)
          (intersection
           (buffer-list-component-hidden-groups component)
           (mapcar #'first (buffer-list-component-filter-groups component))
           :test #'string=)
          (buffer-list-component-all-items component)
          (mapcar #'lem/multi-column-list::wrap
                  (buffer-list-grouped-entries
                   buffers (buffer-list-component-filter-groups component))))
    (dolist (item (buffer-list-component-all-items component))
      (let ((entry (buffer-list-item-entry item)))
        (unless (buffer-list-entry-heading-p entry)
          (alexandria:when-let
              ((mark (gethash (buffer-list-entry-buffer entry) marks)))
            (buffer-list-set-item-mark component item mark)))))
    (buffer-list-sort-all-items component)
    (buffer-list-refresh component :recompute-columns t)
    (buffer-list-focus-buffer component focused-buffer)))

(defun buffer-list-activate-pending-temp-visibility (component)
  "Activate the session visibility regexps staged since the previous `gr'."
  (setf (buffer-list-component-tmp-hide-regexps component)
        (append (buffer-list-component-pending-tmp-hide-regexps component)
                (buffer-list-component-tmp-hide-regexps component))
        (buffer-list-component-tmp-show-regexps component)
        (append (buffer-list-component-pending-tmp-show-regexps component)
                (buffer-list-component-tmp-show-regexps component))
        (buffer-list-component-pending-tmp-hide-regexps component) nil
        (buffer-list-component-pending-tmp-show-regexps component) nil))

(defun buffer-list-rebuild-snapshot
    (component &key (preserve-focused-buffer-p t) focus-index)
  (buffer-list-activate-pending-temp-visibility component)
  (let ((focused-buffer
          (and preserve-focused-buffer-p
               (buffer-list-current-buffer component)))
        (marks (buffer-list-record-marks component))
        (items
          (mapcar #'lem/multi-column-list::wrap
                  (buffer-list-grouped-entries
                   (buffer-list)
                   (buffer-list-component-filter-groups component)))))
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
    (if focus-index
        (buffer-list-focus-index component focus-index)
        (buffer-list-focus-buffer component focused-buffer))
    (message "Ibuffer updated")))

(define-command lem-yath-buffer-list-update () ()
  (buffer-list-rebuild-snapshot
   (lem/multi-column-list::current-multi-column-list)))

(define-command lem-yath-buffer-list-redisplay () ()
  (buffer-list-refresh
   (lem/multi-column-list::current-multi-column-list)
   :recompute-columns t)
  (message "Ibuffer redisplayed"))

(defun buffer-list-ordinary-marked-item-p (component item)
  (and (lem/multi-column-list::multi-column-list-item-checked-p item)
       (not (gethash item (buffer-list-component-deletion-items component)))
       (not (buffer-list-entry-heading-p (buffer-list-item-entry item)))))

(define-command lem-yath-buffer-list-kill-lines () ()
  "Hide visible ordinary-marked rows until the next `gr' update."
  (let* ((component (lem/multi-column-list::current-multi-column-list))
         (visible-items (buffer-list-current-view-items component))
         (focus (buffer-list-current-item component))
         (focus-index (or (position focus visible-items :test #'eq) 0))
         (killed
           (remove-if-not
            (lambda (item)
              (buffer-list-ordinary-marked-item-p component item))
            visible-items)))
    (if (null killed)
        (message "No buffers marked; use m to mark a buffer")
        (progn
          (setf (buffer-list-component-all-items component)
                (remove-if
                 (lambda (item) (member item killed :test #'eq))
                 (buffer-list-component-all-items component)))
          (buffer-list-refresh component :recompute-columns t)
          (buffer-list-focus-index component focus-index)
          (message "Killed ~d lines" (length killed))))))

(defun buffer-list-occur-owned-buffer-p (buffer)
  (and buffer
       (not (deleted-buffer-p buffer))
       (eq (buffer-value buffer :lem-yath-buffer-list-occur-owner)
           +buffer-list-occur-owner+)))

(defun buffer-list-occur-case-fold-p (pattern)
  "Return whether PATTERN has no unescaped uppercase character."
  (loop :with escaped-p := nil
        :for character :across pattern
        :do
           (cond
             (escaped-p (setf escaped-p nil))
             ((char= character #\\) (setf escaped-p t))
             ((upper-case-p character) (return nil)))
        :finally (return t)))

(defun buffer-list-occur-scanner (pattern)
  (handler-case
      (cl-ppcre:create-scanner
       pattern
       :case-insensitive-mode (buffer-list-occur-case-fold-p pattern)
       :multi-line-mode t)
    (error ()
      (editor-error "Invalid Ibuffer Occur regexp"))))

(defun buffer-list-occur-line-starts (text)
  (let ((starts
          (make-array 16 :element-type 'fixnum
                         :adjustable t :fill-pointer 0)))
    (vector-push-extend 0 starts)
    (loop :with cursor := 0
          :for newline := (position #\Newline text :start cursor)
          :while newline
          :do (vector-push-extend (1+ newline) starts)
              (setf cursor (1+ newline)))
    starts))

(defun buffer-list-occur-line-index (starts offset)
  "Return the zero-based source line containing OFFSET."
  (let ((low 0)
        (high (1- (length starts)))
        (answer 0))
    (loop :while (<= low high)
          :for middle := (floor (+ low high) 2)
          :if (<= (aref starts middle) offset)
            :do (setf answer middle
                      low (1+ middle))
          :else
            :do (setf high (1- middle)))
    answer))

(defun buffer-list-occur-line-end-offset (text starts line)
  "Return LINE's exclusive content end, excluding its newline."
  (if (< (1+ line) (length starts))
      (1- (aref starts (1+ line)))
      (length text)))

(defun buffer-list-occur-matches-in-range (scanner text start end)
  "Return nonoverlapping matches wholly inside the half-open START..END range."
  (let ((cursor start)
        matches)
    (loop :while (<= cursor end)
          :do
             (multiple-value-bind (match-start match-end)
                 (cl-ppcre:scan scanner text :start cursor :end end)
               (unless match-start
                 (return))
               (push (make-buffer-list-occur-match
                      :start match-start :end match-end)
                     matches)
               (setf cursor
                     (if (= match-start match-end)
                         (1+ match-end)
                         match-end))))
    (nreverse matches)))

(defun buffer-list-occur-source-data (buffer scanner remaining-matches)
  "Snapshot and scan BUFFER, refusing to exceed REMAINING-MATCHES."
  (let ((size (completion-buffer-size buffer)))
    (when (> size *buffer-list-occur-buffer-character-limit*)
      (editor-error "Ibuffer Occur input ~a exceeds ~d characters"
                    (completion-path-display-string (buffer-name buffer))
                    *buffer-list-occur-buffer-character-limit*)))
  (let* ((text (points-to-string (buffer-start-point buffer)
                                 (buffer-end-point buffer)))
         (length (length text)))
    (let ((starts (buffer-list-occur-line-starts text))
          (cursor 0)
          (match-count 0)
          blocks)
      (loop :while (<= cursor length)
            :do
               (multiple-value-bind (match-start match-end)
                   (cl-ppcre:scan scanner text :start cursor :end length)
                 (unless match-start
                   (return))
                 (let* ((first-line
                          (buffer-list-occur-line-index starts match-start))
                        (last-line
                          (buffer-list-occur-line-index starts match-end))
                        (region-start (aref starts first-line))
                        (region-end
                          (buffer-list-occur-line-end-offset
                           text starts last-line))
                        (matches
                          (buffer-list-occur-matches-in-range
                           scanner text region-start region-end)))
                   ;; The outer match is necessarily in the range.  Retaining
                   ;; it defensively also prevents scanner edge behavior at an
                   ;; empty final line from manufacturing an empty block.
                   (unless matches
                     (setf matches
                           (list (make-buffer-list-occur-match
                                  :start match-start :end match-end))))
                   (incf match-count (length matches))
                   (when (> match-count remaining-matches)
                     (editor-error "Ibuffer Occur exceeds ~d matches"
                                   *buffer-list-occur-match-limit*))
                   (push (make-buffer-list-occur-block
                          :first-line first-line
                          :last-line last-line
                          :matches matches)
                         blocks)
                   (setf cursor
                         (if (< (1+ last-line) (length starts))
                             (aref starts (1+ last-line))
                             (1+ length))))))
      (make-buffer-list-occur-source
       :buffer buffer :text text :line-starts starts
       :blocks (nreverse blocks) :match-count match-count))))

(defun buffer-list-occur-display-character (character)
  (let ((code (char-code character)))
    (case character
      (#\\ "\\\\")
      (#\Tab "\\t")
      (#\Return "\\r")
      (otherwise
       (if (or (not (graphic-char-p character))
               (member (sb-unicode:general-category character)
                       '(:cc :cf :cs :zl :zp)))
           (format nil "\\x~2,'0X;" code)
           (string character))))))

(defun buffer-list-occur-display-line (line)
  "Return a control-safe LINE and a raw-boundary to display-offset map."
  (let ((mapping (make-array (1+ (length line)) :element-type 'fixnum))
        (offset 0)
        (stream (make-string-output-stream)))
    (loop :for character :across line
          :for index :from 0
          :for display := (buffer-list-occur-display-character character)
          :do (setf (aref mapping index) offset)
              (write-string display stream)
              (incf offset (length display)))
    (setf (aref mapping (length line)) offset)
    (values (get-output-stream-string stream) mapping)))

(defun buffer-list-occur-render-append (state text)
  (let* ((start (buffer-list-occur-render-state-length state))
         (end (+ start (length text))))
    (when (> end *buffer-list-occur-output-character-limit*)
      (editor-error "Ibuffer Occur output exceeds ~d characters"
                    *buffer-list-occur-output-character-limit*))
    (push text (buffer-list-occur-render-state-pieces state))
    (setf (buffer-list-occur-render-state-length state) end)
    (values start end)))

(defun buffer-list-occur-render-attribute (state start end attribute)
  (when (< start end)
    (push (make-buffer-list-occur-attribute-spec
           :start start :end end :attribute attribute)
          (buffer-list-occur-render-state-attributes state))))

(defun buffer-list-occur-render-title (state text)
  (multiple-value-bind (start end)
      (buffer-list-occur-render-append
       state (concatenate 'string text (string #\Newline)))
    (buffer-list-occur-render-attribute
     state start (max start (1- end)) 'buffer-list-occur-title-attribute)))

(defun buffer-list-occur-source-line-string (source line)
  (let* ((text (buffer-list-occur-source-text source))
         (starts (buffer-list-occur-source-line-starts source))
         (start (aref starts line))
         (end (buffer-list-occur-line-end-offset text starts line)))
    (values (subseq text start end) start end)))

(defun buffer-list-occur-render-line (state source line &optional block)
  (multiple-value-bind (raw raw-start raw-end)
      (buffer-list-occur-source-line-string source line)
    (multiple-value-bind (display mapping)
        (buffer-list-occur-display-line raw)
      (let* ((prefix
               (if (and block
                        (= line (buffer-list-occur-block-first-line block)))
                   (format nil "~7d:" (1+ line))
                   "       :"))
             (row-start (buffer-list-occur-render-state-length state)))
        (multiple-value-bind (prefix-start prefix-end)
            (buffer-list-occur-render-append state prefix)
          (buffer-list-occur-render-attribute
           state prefix-start prefix-end 'buffer-list-occur-prefix-attribute))
        (let ((content-start (buffer-list-occur-render-state-length state)))
          (buffer-list-occur-render-append state display)
          (when block
            (dolist (match (buffer-list-occur-block-matches block))
              (let ((start (max raw-start
                                (buffer-list-occur-match-start match)))
                    (end (min raw-end
                              (buffer-list-occur-match-end match))))
                (when (< start end)
                  (buffer-list-occur-render-attribute
                   state
                   (+ content-start (aref mapping (- start raw-start)))
                   (+ content-start (aref mapping (- end raw-start)))
                   'buffer-list-occur-match-attribute)))))
          (buffer-list-occur-render-append state (string #\Newline))
          (when block
            (push (make-buffer-list-occur-row-spec
                   :start row-start
                   :end (buffer-list-occur-render-state-length state)
                   :content-start content-start
                   :content-end (+ content-start (length display))
                   :source source
                   :line line
                   :block block)
                  (buffer-list-occur-render-state-rows state))))))))

(defun buffer-list-occur-context-clusters (source context)
  "Return merged context ranges with their ordered match blocks."
  (let (clusters current)
    (dolist (block (buffer-list-occur-source-blocks source))
      (let* ((last-source-line
               (1- (length (buffer-list-occur-source-line-starts source))))
             (start (max 0 (- (buffer-list-occur-block-first-line block)
                              context)))
             (end (min last-source-line
                       (+ (buffer-list-occur-block-last-line block) context))))
        (if (and current (<= start (1+ (second current))))
            (progn
              (setf (second current) (max (second current) end))
              (push block (third current)))
            (progn
              (when current
                (setf (third current) (nreverse (third current)))
                (push current clusters))
              (setf current (list start end (list block)))))))
    (when current
      (setf (third current) (nreverse (third current)))
      (push current clusters))
    (nreverse clusters)))

(defun buffer-list-occur-render-source (state source context)
  (let ((clusters (buffer-list-occur-context-clusters source context)))
    (loop :for cluster :in clusters
          :for first-cluster-p := t :then nil
          :unless first-cluster-p
            :do (buffer-list-occur-render-append
                 state (format nil "-------~%"))
          :do
             (let ((blocks (copy-list (third cluster))))
               (loop :for line :from (first cluster) :to (second cluster)
                     :do
                        (loop :while
                          (and blocks
                               (< (buffer-list-occur-block-last-line
                                   (first blocks))
                                  line))
                              :do (pop blocks))
                        (let ((block
                                (and blocks
                                     (<= (buffer-list-occur-block-first-line
                                          (first blocks))
                                         line)
                                     (<= line
                                         (buffer-list-occur-block-last-line
                                          (first blocks)))
                                     (first blocks))))
                          (buffer-list-occur-render-line
                           state source line block)))))))

(defun buffer-list-occur-count-words (matches lines)
  (format nil "~d ~a~a"
          matches
          (if (= matches 1) "match" "matches")
          (if (= matches lines)
              ""
              (format nil " in ~d ~a"
                      lines (if (= lines 1) "line" "lines")))))

(defun buffer-list-occur-render-output (sources pattern context)
  (let* ((state (make-buffer-list-occur-render-state))
         (matching (remove-if (lambda (source)
                                (zerop (buffer-list-occur-source-match-count
                                        source)))
                              sources))
         (total-matches
           (reduce #'+ sources :key #'buffer-list-occur-source-match-count
                               :initial-value 0))
         (total-lines
           (reduce #'+ sources
                   :key (lambda (source)
                          (length (buffer-list-occur-source-blocks source)))
                   :initial-value 0))
         (pattern-display (completion-path-display-string pattern))
         (multiple-p (> (length sources) 1)))
    (when (and multiple-p (plusp total-matches))
      (buffer-list-occur-render-title
       state
       (format nil "~a total for \"~a\":"
               (buffer-list-occur-count-words total-matches total-lines)
               pattern-display)))
    (dolist (source matching)
      (let* ((matches (buffer-list-occur-source-match-count source))
             (lines (length (buffer-list-occur-source-blocks source)))
             (regexp-suffix
               (if multiple-p ""
                   (format nil " for \"~a\"" pattern-display))))
        (buffer-list-occur-render-title
         state
         (format nil "~a~a in buffer: ~a"
                 (buffer-list-occur-count-words matches lines)
                 regexp-suffix
                 (completion-path-display-string
                  (buffer-name (buffer-list-occur-source-buffer source)))))
        (buffer-list-occur-render-source state source context)))
    (values
     state
     (with-output-to-string (stream)
       (dolist (piece (nreverse
                       (buffer-list-occur-render-state-pieces state)))
         (write-string piece stream)))
     total-matches)))

(defun buffer-list-occur-point-at-offset (buffer offset)
  (let ((point (copy-point (buffer-start-point buffer) :temporary)))
    (unless (move-to-position point (1+ offset))
      (error "Stale Occur source offset ~d in ~a" offset (buffer-name buffer)))
    (copy-point point :right-inserting)))

(defun buffer-list-occur-delete-targets (targets)
  (dolist (target targets)
    (ignore-errors (delete-point (buffer-list-occur-target-start target)))
    (ignore-errors (delete-point (buffer-list-occur-target-end target)))))

(defun buffer-list-occur-delete-line-targets (targets)
  (dolist (target targets)
    (ignore-errors
      (delete-point (buffer-list-occur-line-target-source-start target)))
    (ignore-errors
      (delete-point (buffer-list-occur-line-target-source-end target)))
    (ignore-errors
      (delete-point (buffer-list-occur-line-target-result-start target)))
    (ignore-errors
      (delete-point (buffer-list-occur-line-target-result-end target)))))

(defun buffer-list-occur-target-map (sources)
  (let ((map (make-hash-table :test #'eq))
        targets)
    (handler-case
        (progn
          (dolist (source sources)
            (let ((buffer (buffer-list-occur-source-buffer source)))
              (unless (and (not (deleted-buffer-p buffer))
                           (eq buffer (get-buffer (buffer-name buffer))))
                (editor-error "Ibuffer Occur source was killed"))
              (dolist (block (buffer-list-occur-source-blocks source))
                (let ((block-targets
                        (mapcar
                         (lambda (match)
                           (let ((target
                                   (make-buffer-list-occur-target
                                    :buffer buffer
                                    :start
                                    (buffer-list-occur-point-at-offset
                                     buffer
                                     (buffer-list-occur-match-start match))
                                    :end
                                    (buffer-list-occur-point-at-offset
                                     buffer
                                     (buffer-list-occur-match-end match)))))
                             (push target targets)
                             target))
                         (buffer-list-occur-block-matches block))))
                  (setf (gethash block map) block-targets)))))
          (values map targets))
      (error (condition)
        (buffer-list-occur-delete-targets targets)
        (error condition)))))

(defun buffer-list-occur-cleanup-buffer (buffer)
  (let ((targets (buffer-value buffer :lem-yath-buffer-list-occur-targets))
        (line-targets
          (buffer-value buffer :lem-yath-buffer-list-occur-line-targets)))
    (setf (buffer-value buffer :lem-yath-buffer-list-occur-targets) nil
          (buffer-value buffer :lem-yath-buffer-list-occur-line-targets) nil)
    (buffer-list-occur-delete-targets targets)
    (buffer-list-occur-delete-line-targets line-targets)))

(defun buffer-list-occur-source-point-at-offset (buffer offset insertion-type)
  (let ((point (copy-point (buffer-start-point buffer) :temporary)))
    (unless (move-to-position point (1+ offset))
      (error "Stale Occur source offset ~d in ~a" offset (buffer-name buffer)))
    (copy-point point insertion-type)))

(defun buffer-list-occur-make-line-target (output row)
  (let* ((source (buffer-list-occur-row-spec-source row))
         (buffer (buffer-list-occur-source-buffer source))
         (line (buffer-list-occur-row-spec-line row)))
    (multiple-value-bind (_raw raw-start raw-end)
        (buffer-list-occur-source-line-string source line)
      (declare (ignore _raw))
      (make-buffer-list-occur-line-target
       :buffer buffer
       :source-start
       (buffer-list-occur-source-point-at-offset buffer raw-start :right-inserting)
       :source-end
       (buffer-list-occur-source-point-at-offset buffer raw-end :left-inserting)
       :result-start
       (buffer-list-occur-source-point-at-offset
        output (buffer-list-occur-row-spec-content-start row) :right-inserting)
       :result-end
       (buffer-list-occur-source-point-at-offset
        output (buffer-list-occur-row-spec-content-end row) :left-inserting)))))

(defun buffer-list-occur-put-property (buffer start end property value)
  (let ((start-point (copy-point (buffer-start-point buffer) :temporary))
        (end-point (copy-point (buffer-start-point buffer) :temporary)))
    (unless (and (move-to-position start-point (1+ start))
                 (move-to-position end-point (1+ end)))
      (error "Invalid Ibuffer Occur output range ~d..~d" start end))
    (put-text-property start-point end-point property value)))

(defun buffer-list-occur-prepare-output-buffer (sources)
  (let ((buffer (get-buffer *buffer-list-occur-buffer-name*)))
    (when (and buffer
               (member buffer sources
                       :key #'buffer-list-occur-source-buffer :test #'eq))
      (unless (buffer-list-occur-owned-buffer-p buffer)
        (editor-error "Buffer ~a exists but is not a lem-yath Occur result"
                      *buffer-list-occur-buffer-name*))
      (buffer-rename buffer (unique-buffer-name *buffer-list-occur-buffer-name*))
      (setf buffer nil))
    buffer))

(defun buffer-list-occur-clear-empty-output (sources)
  "Remove a stale owned result without ever killing one of SOURCES."
  (alexandria:when-let
      ((buffer (get-buffer *buffer-list-occur-buffer-name*)))
    (when (buffer-list-occur-owned-buffer-p buffer)
      (if (member buffer sources
                  :key #'buffer-list-occur-source-buffer :test #'eq)
          (buffer-rename
           buffer (unique-buffer-name *buffer-list-occur-buffer-name*))
          (kill-buffer buffer)))))

(defun buffer-list-occur-install-output
    (sources state text pattern context target-map targets &optional output-name)
  (let ((buffer (if output-name
                    (get-buffer output-name)
                    (buffer-list-occur-prepare-output-buffer sources)))
        (line-targets nil)
        (installed-p nil))
    (when (and buffer (not (buffer-list-occur-owned-buffer-p buffer)))
      (buffer-list-occur-delete-targets targets)
      (editor-error "Buffer ~a exists but is not a lem-yath Occur result"
                    *buffer-list-occur-buffer-name*))
    (unless buffer
      (setf buffer
            (make-buffer (or output-name *buffer-list-occur-buffer-name*)
                         :enable-undo-p nil)))
    (unwind-protect
         (progn
           (buffer-list-occur-cleanup-buffer buffer)
           (buffer-disable-undo buffer)
           (with-buffer-read-only buffer nil
             (erase-buffer buffer)
             (insert-string (buffer-start-point buffer) text))
           (change-buffer-mode buffer 'buffer-list-occur-mode)
           (dolist (attribute
                    (buffer-list-occur-render-state-attributes state))
             (buffer-list-occur-put-property
              buffer
              (buffer-list-occur-attribute-spec-start attribute)
              (buffer-list-occur-attribute-spec-end attribute)
              :attribute
              (buffer-list-occur-attribute-spec-attribute attribute)))
           (dolist (row (buffer-list-occur-render-state-rows state))
             (buffer-list-occur-put-property
              buffer
              (buffer-list-occur-row-spec-start row)
              (buffer-list-occur-row-spec-end row)
              :buffer-list-occur-targets
              (gethash (buffer-list-occur-row-spec-block row) target-map))
             (let ((target (buffer-list-occur-make-line-target buffer row)))
               (push target line-targets)
               (buffer-list-occur-put-property
                buffer
                (buffer-list-occur-row-spec-content-start row)
                (buffer-list-occur-row-spec-content-end row)
                :buffer-list-occur-edit-target
                target)))
           (setf (buffer-value buffer :lem-yath-buffer-list-occur-owner)
                 +buffer-list-occur-owner+
                 (buffer-value buffer :lem-yath-buffer-list-occur-targets)
                 targets
                 (buffer-value buffer :lem-yath-buffer-list-occur-line-targets)
                 line-targets
                 (buffer-value buffer :lem-yath-buffer-list-occur-regexp)
                 pattern
                 (buffer-value buffer :lem-yath-buffer-list-occur-context)
                 context
                 (buffer-value buffer :lem-yath-buffer-list-occur-sources)
                 (mapcar #'buffer-list-occur-source-buffer sources))
           (buffer-start (buffer-point buffer))
           (buffer-mark-saved buffer)
           (setf (buffer-read-only-p buffer) t
                 installed-p t)
           buffer)
      (unless installed-p
        (buffer-list-occur-delete-targets targets)
        (buffer-list-occur-delete-line-targets line-targets)))))

(defun buffer-list-occur-action-buffers (component)
  "Return ordinary marked buffers in GNU Ibuffer's reverse display order."
  (let ((marked
          (loop :for item :in (buffer-list-component-all-items component)
                :for entry := (buffer-list-item-entry item)
                :for buffer := (unless (buffer-list-entry-heading-p entry)
                                 (buffer-list-entry-buffer entry))
                :when (and buffer
                           (buffer-list-ordinary-marked-item-p component item)
                           (buffer-list-active-filters-match-p component buffer)
                           (not (deleted-buffer-p buffer))
                           (eq buffer (get-buffer (buffer-name buffer))))
                  :collect buffer)))
    (if marked
        (nreverse marked)
        (let ((item (buffer-list-current-item component))
              (buffer (buffer-list-require-current-buffer component)))
          ;; GNU ibuffer-do-occur leaves this implicit ordinary mark behind.
          (buffer-list-set-item-mark component item :marked)
          (lem/multi-column-list:update component)
          (list buffer)))))

(defun buffer-list-occur-run (component buffers pattern context)
  (let ((scanner (buffer-list-occur-scanner pattern))
        (total-characters
          (reduce #'+ buffers :key #'completion-buffer-size
                              :initial-value 0))
        (remaining-matches *buffer-list-occur-match-limit*)
        sources)
    (when (> total-characters *buffer-list-occur-total-character-limit*)
      (editor-error "Ibuffer Occur input exceeds ~d total characters"
                    *buffer-list-occur-total-character-limit*))
    (dolist (buffer buffers)
      (let ((source
              (buffer-list-occur-source-data
               buffer scanner remaining-matches)))
        (decf remaining-matches
              (buffer-list-occur-source-match-count source))
        (push source sources)))
    (setf sources (nreverse sources))
    (multiple-value-bind (state text total-matches)
        (buffer-list-occur-render-output sources pattern context)
      (if (zerop total-matches)
          (progn
            (buffer-list-occur-clear-empty-output sources)
            (message "Searched ~d ~a; no matches for \"~a\""
                     (length buffers)
                     (if (= (length buffers) 1) "buffer" "buffers")
                     (completion-path-display-string pattern))
            nil)
          (multiple-value-bind (target-map targets)
              (buffer-list-occur-target-map sources)
            (let ((occur-buffer
                    (buffer-list-occur-install-output
                     sources state text pattern context target-map targets))
                  (source-window (buffer-list-source-window component)))
              (with-current-window source-window
                (pop-to-buffer occur-buffer :split-action :sensibly))
              (message "Searched ~d ~a; ~d ~a for \"~a\""
                       (length buffers)
                       (if (= (length buffers) 1) "buffer" "buffers")
                       total-matches
                       (if (= total-matches 1) "match" "matches")
                       (completion-path-display-string pattern))
              occur-buffer))))))

(define-command lem-yath-buffer-list-occur (argument) (:universal-nil)
  "Run GNU-style Occur over ordinary-marked Ibuffer rows."
  (let* ((component (lem/multi-column-list::current-multi-column-list))
         (pattern
           (prompt-for-string
            "List lines matching regexp: "
            :initial-value
            (and (boundp '*regexp-search-history*)
                 (first (symbol-value '*regexp-search-history*)))
            :history-symbol 'lem-yath-occur-regexp))
         (buffers (buffer-list-occur-action-buffers component))
         (context (if (and (integerp argument) (not (minusp argument)))
                      argument
                      0)))
    (add-search-history pattern t)
    (when (zerop (length pattern))
      (editor-error "Occur does not accept an empty regexp"))
    (buffer-list-occur-run component buffers pattern context)))

(defun buffer-list-occur-current-targets ()
  (unless (member (buffer-major-mode (current-buffer))
                  '(buffer-list-occur-mode buffer-list-occur-edit-mode)
                  :test #'eq)
    (editor-error "Not in an Occur buffer"))
  (let ((point (copy-point (current-point) :temporary)))
    (line-start point)
    (or (text-property-at point :buffer-list-occur-targets)
        (editor-error "No occurrence on this line"))))

(defun buffer-list-occur-validate-target (target)
  (let ((buffer (buffer-list-occur-target-buffer target))
        (start (buffer-list-occur-target-start target)))
    (unless (and buffer
                 (not (deleted-buffer-p buffer))
                 (alive-point-p start)
                 (eq buffer (point-buffer start)))
      (editor-error "Buffer for this occurrence was killed"))
    target))

(defun buffer-list-occur-show-target (target select-p)
  (buffer-list-occur-validate-target target)
  (let* ((occur-window (current-window))
         (buffer (buffer-list-occur-target-buffer target))
         (target-window (pop-to-buffer buffer :split-action :sensibly)))
    (with-current-window target-window
      (lem-vi-mode/jumplist:with-jumplist
        (switch-to-buffer buffer)
        (move-point (current-point) (buffer-list-occur-target-start target)))
      (window-recenter target-window))
    (switch-to-window (if select-p target-window occur-window))
    target))

(define-command lem-yath-buffer-list-occur-visit () ()
  (buffer-list-occur-show-target
   (first (buffer-list-occur-current-targets)) t))

(define-command lem-yath-buffer-list-occur-display () ()
  (buffer-list-occur-show-target
   (first (buffer-list-occur-current-targets)) nil))

(defun buffer-list-occur-move (direction)
  (let ((point (copy-point (current-point) :temporary)))
    (line-start point)
    (let ((current-targets
            (text-property-at point :buffer-list-occur-targets)))
      (loop :while (line-offset point direction)
          :for targets := (text-property-at point
                                             :buffer-list-occur-targets)
          :when (and targets (not (eq targets current-targets)))
            :do (move-point (current-point) point)
                (buffer-list-occur-show-target (first targets) nil)
                (return targets)
          :finally
             (editor-error (if (plusp direction)
                               "No more matches"
                               "No earlier matches"))))))

(define-command lem-yath-buffer-list-occur-next () ()
  (buffer-list-occur-move 1))

(define-command lem-yath-buffer-list-occur-previous () ()
  (buffer-list-occur-move -1))

(defun buffer-list-occur-line-target-live-p (target)
  (let ((buffer (buffer-list-occur-line-target-buffer target)))
    (and buffer
         (not (deleted-buffer-p buffer))
         (eq buffer (get-buffer (buffer-name buffer)))
         (alive-point-p (buffer-list-occur-line-target-source-start target))
         (alive-point-p (buffer-list-occur-line-target-source-end target))
         (alive-point-p (buffer-list-occur-line-target-result-start target))
         (alive-point-p (buffer-list-occur-line-target-result-end target)))))

(defun buffer-list-occur-edit-target-for-change (buffer point change)
  (let* ((position (position-at-point point))
         (change-end (+ position (if (integerp change) change 0))))
    (find-if
     (lambda (target)
       (and (buffer-list-occur-line-target-live-p target)
            (<= (position-at-point
                 (buffer-list-occur-line-target-result-start target))
                position)
            (<= change-end
                (position-at-point
                 (buffer-list-occur-line-target-result-end target)))))
     (buffer-value buffer :lem-yath-buffer-list-occur-line-targets))))

(defun buffer-list-occur-edit-before-change (point change)
  (let* ((buffer (point-buffer point))
         (target
           (buffer-list-occur-edit-target-for-change buffer point change)))
    (unless target
      (editor-error "Occur headings, prefixes, and row boundaries are read-only"))
    (when (and (stringp change)
               (find-if (lambda (character)
                          (member character '(#\Newline #\Return)))
                        change))
      (editor-error "Occur Edit cannot create result rows"))
    (let ((source (buffer-list-occur-line-target-buffer target)))
      (when (buffer-read-only-p source)
        (editor-error "Occur source buffer ~a is read-only"
                      (buffer-name source))))
    (let* ((row-start
             (position-at-point
              (buffer-list-occur-line-target-result-start target)))
           (relative (- (position-at-point point) row-start))
           (display
             (points-to-string
              (buffer-list-occur-line-target-result-start target)
              (buffer-list-occur-line-target-result-end target)))
           (proposed
             (if (stringp change)
                 (concatenate 'string
                              (subseq display 0 relative)
                              change
                              (subseq display relative))
                 (concatenate 'string
                              (subseq display 0 relative)
                              (subseq display (+ relative change))))))
      (buffer-list-occur-replace-source-line
       target (buffer-list-occur-decode-display-line proposed))
      (setf (buffer-value buffer :lem-yath-buffer-list-occur-edit-pending)
            target))))

(defun buffer-list-occur-decode-display-line (display)
  "Decode the control-safe Occur DISPLAY representation into source text."
  (with-output-to-string (stream)
    (loop :with index := 0
          :while (< index (length display))
          :for character := (char display index)
          :do
             (if (and (char= character #\\)
                      (< (1+ index) (length display)))
                 (let ((next (char display (1+ index))))
                   (cond
                     ((char= next #\\)
                      (write-char #\\ stream)
                      (incf index 2))
                     ((char= next #\t)
                      (write-char #\Tab stream)
                      (incf index 2))
                     ((char= next #\r)
                      (write-char #\Return stream)
                      (incf index 2))
                     ((and (char= next #\x)
                           (alexandria:when-let
                               ((semicolon (position #\; display
                                                     :start (+ index 2))))
                             (let ((digits (subseq display (+ index 2)
                                                   semicolon)))
                               (and (plusp (length digits))
                                    (every (lambda (digit)
                                             (digit-char-p digit 16))
                                           digits)
                                    (progn
                                      (write-char
                                       (code-char (parse-integer digits
                                                                 :radix 16))
                                       stream)
                                      (setf index (1+ semicolon)))))))
                      nil)
                     (t
                      (write-char character stream)
                      (incf index))))
                 (progn
                   (write-char character stream)
                   (incf index))))))

(defun buffer-list-occur-replace-source-line (target replacement)
  (when (find #\Newline replacement)
    (editor-error "Occur Edit cannot insert a source newline through an escaped row"))
  (let* ((buffer (buffer-list-occur-line-target-buffer target))
         (start (buffer-list-occur-line-target-source-start target))
         (end (buffer-list-occur-line-target-source-end target))
         (group (buffer-prepare-change-group buffer)))
    (handler-case
        (progn
          (delete-between-points start end)
          (insert-string start replacement)
          (buffer-accept-change-group group))
      (error (condition)
        (when (buffer-change-group-active-p group)
          (ignore-errors (buffer-cancel-change-group group)))
        (error condition)))))

(defun buffer-list-occur-edit-after-change (start end old-length)
  (declare (ignore start end old-length))
  (let* ((result (current-buffer))
         (target
           (buffer-value result :lem-yath-buffer-list-occur-edit-pending)))
    (setf (buffer-value result :lem-yath-buffer-list-occur-edit-pending) nil)
    (when target
      (put-text-property
       (buffer-list-occur-line-target-result-start target)
       (buffer-list-occur-line-target-result-end target)
       :buffer-list-occur-edit-target target)
      (remove-text-property
       (buffer-list-occur-line-target-result-start target)
       (buffer-list-occur-line-target-result-end target)
       :read-only))))

(define-command lem-yath-buffer-list-occur-edit () ()
  (let* ((buffer (current-buffer))
         (targets
           (buffer-value buffer :lem-yath-buffer-list-occur-line-targets)))
    (unless (and (eq (buffer-major-mode buffer) 'buffer-list-occur-mode)
                 targets)
      (editor-error "This is not an editable Occur result"))
    (unless (buffer-enable-undo-p buffer)
      (buffer-enable-undo buffer))
    (put-text-property (buffer-start-point buffer) (buffer-end-point buffer)
                       :read-only t)
    (dolist (target targets)
      (when (buffer-list-occur-line-target-live-p target)
        (remove-text-property
         (buffer-list-occur-line-target-result-start target)
         (buffer-list-occur-line-target-result-end target)
         :read-only)))
    (setf (buffer-read-only-p buffer) nil)
    (change-buffer-mode buffer 'buffer-list-occur-edit-mode)
    (add-hook (variable-value 'before-change-functions :buffer buffer)
              'buffer-list-occur-edit-before-change)
    (add-hook (variable-value 'after-change-functions :buffer buffer)
              'buffer-list-occur-edit-after-change)
    (message "Editing Occur: C-c C-c returns to Occur mode")))

(define-command lem-yath-buffer-list-occur-cease-edit () ()
  (let ((buffer (current-buffer)))
    (unless (eq (buffer-major-mode buffer) 'buffer-list-occur-edit-mode)
      (editor-error "Occur Edit is not active"))
    (remove-hook (variable-value 'before-change-functions :buffer buffer)
                 'buffer-list-occur-edit-before-change)
    (remove-hook (variable-value 'after-change-functions :buffer buffer)
                 'buffer-list-occur-edit-after-change)
    (setf (buffer-value buffer :lem-yath-buffer-list-occur-edit-pending) nil)
    (remove-text-property (buffer-start-point buffer) (buffer-end-point buffer)
                          :read-only)
    (setf (buffer-read-only-p buffer) t)
    (change-buffer-mode buffer 'buffer-list-occur-mode)
    (let ((state (lem-vi-mode/core:current-state)))
      (when (and state
                 (not (lem-vi-mode/core:state=
                       state
                       (lem-vi-mode/core:ensure-state
                        'lem-vi-mode/states:normal))))
        (lem-vi-mode/commands:vi-normal)))
    (message "Switching to Occur mode")))

(define-command lem-yath-buffer-list-occur-edit-escape () ()
  (let ((state (lem-vi-mode/core:current-state)))
    (if (and state
             (not (lem-vi-mode/core:state=
                   state
                   (lem-vi-mode/core:ensure-state
                    'lem-vi-mode/states:normal))))
        (lem-vi-mode/commands:vi-normal)
        (lem-yath-buffer-list-occur-cease-edit))))

(define-command lem-yath-buffer-list-occur-rename () ()
  (let* ((buffer (current-buffer))
         (sources (buffer-value buffer :lem-yath-buffer-list-occur-sources)))
    (unless (and (buffer-list-occur-owned-buffer-p buffer) sources)
      (editor-error "This is not an owned Occur result"))
    (unless (every #'buffer-list-multi-isearch-live-buffer-p sources)
      (editor-error "Cannot rename Occur: source buffer was killed"))
    (let ((name
            (format nil "*Occur: ~{~a~^/~}*"
                    (mapcar #'buffer-name sources))))
      (buffer-rename buffer name)
      (message "Renamed Occur result to ~a" name))))

(defun buffer-list-occur-clone-sources (buffers pattern)
  (let ((scanner (buffer-list-occur-scanner pattern))
        (total-characters 0)
        (remaining *buffer-list-occur-match-limit*)
        sources)
    (dolist (buffer buffers (nreverse sources))
      (unless (buffer-list-multi-isearch-live-buffer-p buffer)
        (editor-error "Cannot clone Occur: source buffer was killed"))
      (incf total-characters (completion-buffer-size buffer))
      (when (> total-characters *buffer-list-occur-total-character-limit*)
        (editor-error "Cannot clone Occur: input exceeds ~d total characters"
                      *buffer-list-occur-total-character-limit*))
      (let ((source (buffer-list-occur-source-data buffer scanner remaining)))
        (decf remaining (buffer-list-occur-source-match-count source))
        (push source sources)))))

(define-command lem-yath-buffer-list-occur-clone () ()
  (let* ((original (current-buffer))
         (position (position-at-point (current-point)))
         (pattern
           (buffer-value original :lem-yath-buffer-list-occur-regexp))
         (context
           (buffer-value original :lem-yath-buffer-list-occur-context))
         (buffers
           (buffer-value original :lem-yath-buffer-list-occur-sources)))
    (unless (and (buffer-list-occur-owned-buffer-p original) pattern buffers)
      (editor-error "This is not a cloneable Occur result"))
    (let ((sources (buffer-list-occur-clone-sources buffers pattern))
          (name (buffer-list-emacs-unique-name original)))
      (multiple-value-bind (state text total)
          (buffer-list-occur-render-output sources pattern context)
        (when (zerop total)
          (editor-error "Cannot clone Occur: sources no longer match"))
        (multiple-value-bind (target-map targets)
            (buffer-list-occur-target-map sources)
          (let ((clone
                  (buffer-list-occur-install-output
                   sources state text pattern context target-map targets name)))
            (switch-to-buffer clone)
            (move-to-position
             (current-point)
             (min position (position-at-point (buffer-end-point clone))))
            (message "Cloned Occur result as ~a" (buffer-name clone))))))))

(defun buffer-list-occur-kill-buffer-hook (buffer)
  (when (buffer-list-occur-owned-buffer-p buffer)
    (buffer-list-occur-cleanup-buffer buffer)))

(defun buffer-list-multi-isearch-live-buffer-p (buffer)
  (and buffer
       (not (deleted-buffer-p buffer))
       (eq buffer (get-buffer (buffer-name buffer)))))

(defun buffer-list-multi-isearch-live-buffers (session)
  (let ((buffers
          (remove-if-not #'buffer-list-multi-isearch-live-buffer-p
                         (buffer-list-multi-isearch-session-buffers session))))
    (setf (buffer-list-multi-isearch-session-buffers session) buffers)
    buffers))

(defun buffer-list-multi-isearch-marked-buffers (component)
  "Return visible ordinary marks in GNU Ibuffer's display order."
  (loop :for item :in (lem/multi-column-list::multi-column-list-items component)
        :for entry := (buffer-list-item-entry item)
        :for buffer := (unless (buffer-list-entry-heading-p entry)
                         (buffer-list-entry-buffer entry))
        :when (and buffer
                   (buffer-list-ordinary-marked-item-p component item)
                   (buffer-list-multi-isearch-live-buffer-p buffer))
          :collect buffer))

(defun buffer-list-multi-isearch-enable-current-modes ()
  (unless (mode-active-p (current-buffer) 'lem/isearch:isearch-mode)
    (lem/isearch:isearch-mode t))
  (unless (mode-active-p (current-buffer) 'buffer-list-multi-isearch-mode)
    (buffer-list-multi-isearch-mode t)))

(defun buffer-list-multi-isearch-switch-to-point (point)
  (let ((buffer (point-buffer point)))
    (unless (buffer-list-multi-isearch-live-buffer-p buffer)
      (editor-error "Ibuffer multi-isearch source was killed"))
    (unless (eq buffer (current-buffer))
      (switch-to-buffer buffer))
    (buffer-list-multi-isearch-enable-current-modes)
    (move-point (current-point) point)
    t))

(defun buffer-list-multi-isearch-search-from (buffer direction string
                                              &optional point limit)
  (let* ((session *buffer-list-multi-isearch-session*)
         (function
           (ecase direction
             (:forward
              (buffer-list-multi-isearch-session-forward-function session))
             (:backward
              (buffer-list-multi-isearch-session-backward-function session))))
         (point
           (or point
               (ecase direction
                 (:forward (buffer-start-point buffer))
                 (:backward (buffer-end-point buffer))))))
    (with-point ((candidate point))
      (when (funcall function candidate string limit)
        (copy-point candidate :temporary)))))

(defun buffer-list-multi-isearch-reset-to-start (session)
  (let ((buffer (buffer-list-multi-isearch-session-start-buffer session))
        (point (buffer-list-multi-isearch-session-start-point session)))
    (when (and (buffer-list-multi-isearch-live-buffer-p buffer)
               (alive-point-p point))
      (unless (eq buffer (current-buffer))
        (switch-to-buffer buffer))
      (buffer-list-multi-isearch-enable-current-modes)
      (move-point (current-point) point)
      t)))

(defun buffer-list-multi-isearch-edit-search (_point string)
  "Find the first current-or-later match after an isearch input edit.

GNU multi-isearch pauses in the initial buffer until an explicit repeat.  Once
the search has crossed a buffer boundary, refining the input may continue
through later selected buffers without wrapping."
  (declare (ignore _point))
  (let* ((session *buffer-list-multi-isearch-session*)
         (buffers (and session
                       (buffer-list-multi-isearch-live-buffers session))))
    (unless buffers
      (editor-error "Ibuffer multi-isearch has no live sources"))
    (when (zerop (length string))
      (setf (variable-value 'lem/isearch::isearch-next-last :buffer) nil
            (variable-value 'lem/isearch::isearch-prev-last :buffer) nil)
      (return-from buffer-list-multi-isearch-edit-search
        (buffer-list-multi-isearch-reset-to-start session)))
    (let* ((first (first buffers))
           (current (if (member (current-buffer) buffers :test #'eq)
                        (current-buffer)
                        first))
           (candidates
             (if (eq current first)
                 (list first)
                 (member current buffers :test #'eq))))
      (dolist (buffer candidates)
        (alexandria:when-let
            ((match (buffer-list-multi-isearch-search-from
                     buffer :forward string)))
          (return-from buffer-list-multi-isearch-edit-search
            (progn
              (setf (variable-value
                     'lem/isearch::isearch-next-last :buffer) nil)
              (buffer-list-multi-isearch-switch-to-point match)))))
      (setf (variable-value 'lem/isearch::isearch-next-last :buffer) t)
      (buffer-list-multi-isearch-reset-to-start session)
      nil)))

(defun buffer-list-multi-isearch-search-step (direction)
  (let* ((session *buffer-list-multi-isearch-session*)
         (buffers (and session
                       (buffer-list-multi-isearch-live-buffers session))))
    (unless buffers
      (editor-error "Ibuffer multi-isearch has no live sources"))
    (when (string= lem/isearch::*isearch-string* "")
      (setf lem/isearch::*isearch-string*
            (lem/isearch::isearch-default-string)))
    (let* ((current
             (if (member (current-buffer) buffers :test #'eq)
                 (current-buffer)
                 (first buffers)))
           (start-index (or (position current buffers :test #'eq) 0))
           (count (length buffers))
           (origin (copy-point (current-point) :temporary)))
      ;; OFFSET=COUNT revisits the current buffer from its opposite boundary,
      ;; reproducing isearch's ordinary wrap after every other marked buffer.
      (loop :for offset :from 0 :to count
            :for index := (mod (if (eq direction :forward)
                                  (+ start-index offset)
                                  (- start-index offset))
                               count)
            :for buffer := (nth index buffers)
            :for wrapped-current-p := (= offset count)
            :for point := (cond
                            ((zerop offset) origin)
                            ((eq direction :forward)
                             (buffer-start-point buffer))
                            (t (buffer-end-point buffer)))
            :for limit := (and wrapped-current-p origin)
            :for match := (buffer-list-multi-isearch-search-from
                           buffer direction lem/isearch::*isearch-string*
                           point limit)
            :when match
              :do (buffer-list-multi-isearch-switch-to-point match)
                  (return t)
            :finally (return nil)))))

(define-command lem-yath-buffer-list-multi-isearch-next () ()
  (setf (variable-value 'lem/isearch::isearch-prev-last :buffer) nil)
  (if (buffer-list-multi-isearch-search-step :forward)
      (setf (variable-value 'lem/isearch::isearch-next-last :buffer) nil)
      (setf (variable-value 'lem/isearch::isearch-next-last :buffer) t))
  (lem/isearch::isearch-update-display))

(define-command lem-yath-buffer-list-multi-isearch-previous () ()
  (setf (variable-value 'lem/isearch::isearch-next-last :buffer) nil)
  (if (buffer-list-multi-isearch-search-step :backward)
      (setf (variable-value 'lem/isearch::isearch-prev-last :buffer) nil)
      (setf (variable-value 'lem/isearch::isearch-prev-last :buffer) t))
  (lem/isearch::isearch-update-display))

(defun buffer-list-multi-isearch-cleanup (&key keep-current-highlight)
  (alexandria:when-let ((session *buffer-list-multi-isearch-session*))
    (let ((highlight-buffer (and keep-current-highlight (current-buffer))))
      ;; Clear the global marker before mode disable hooks can run commands that
      ;; would otherwise see a half-torn-down session.
      (setf *buffer-list-multi-isearch-session* nil)
      (dolist (buffer (buffer-list-multi-isearch-live-buffers session))
        (with-current-buffer buffer
          (unless (eq buffer highlight-buffer)
            (lem/isearch::isearch-reset-overlays buffer)
            (buffer-unbound buffer 'lem/isearch::isearch-redisplay-string)
            (remove-hook (variable-value 'after-change-functions :buffer)
                         'lem/isearch::isearch-change-buffer-hook))
          (when (mode-active-p buffer 'buffer-list-multi-isearch-mode)
            (buffer-list-multi-isearch-mode nil))
          (when (mode-active-p buffer 'lem/isearch:isearch-mode)
            (lem/isearch:isearch-mode nil)))))))

(define-command lem-yath-buffer-list-multi-isearch-abort () ()
  (let ((session *buffer-list-multi-isearch-session*))
    (unless session
      (editor-error "No Ibuffer multi-isearch is active"))
    (when (null (buffer-fake-cursors (current-buffer)))
      (buffer-list-multi-isearch-reset-to-start session))
    (when (mode-active-p (current-buffer) 'lem/isearch:isearch-mode)
      (lem/isearch::isearch-end))
    (buffer-list-multi-isearch-cleanup)))

(defun buffer-list-multi-isearch-post-command ()
  (when *buffer-list-multi-isearch-session*
    (unless (and (mode-active-p (current-buffer)
                                'buffer-list-multi-isearch-mode)
                 (mode-active-p (current-buffer) 'lem/isearch:isearch-mode))
      (buffer-list-multi-isearch-cleanup
       :keep-current-highlight
       (not (null (buffer-value
                   (current-buffer) 'lem/isearch::isearch-redisplay-string)))))))

(defun buffer-list-multi-isearch-start (regexp-p)
  (when *buffer-list-multi-isearch-session*
    (editor-error "An Ibuffer multi-isearch is already active"))
  (let* ((component (lem/multi-column-list::current-multi-column-list))
         (buffers (buffer-list-multi-isearch-marked-buffers component)))
    (unless buffers
      (editor-error "No ordinarily marked buffers for Ibuffer multi-isearch"))
    (let* ((first (first buffers))
           (forward (if regexp-p #'search-forward-regexp #'search-forward))
           (backward (if regexp-p #'search-backward-regexp #'search-backward)))
      (lem/multi-column-list:quit component)
      (switch-to-buffer first)
      (buffer-start (current-point))
      (setf *buffer-list-multi-isearch-session*
            (make-buffer-list-multi-isearch-session
             :buffers buffers
             :start-buffer first
             :start-point (copy-point (current-point) :temporary)
             :forward-function forward
             :backward-function backward
             :regexp-p regexp-p))
      (handler-case
          (progn
            (lem/isearch::isearch-start
             (if regexp-p "M-ISearch Regexp: " "M-ISearch: ")
             #'buffer-list-multi-isearch-edit-search
             forward backward "")
            (buffer-list-multi-isearch-mode t))
        (error (condition)
          (buffer-list-multi-isearch-cleanup)
          (error condition))))))

(define-command lem-yath-buffer-list-multi-isearch () ()
  (buffer-list-multi-isearch-start nil))

(define-command lem-yath-buffer-list-multi-isearch-regexp () ()
  (buffer-list-multi-isearch-start t))

(defvar *buffer-list-query-replace-before* nil)
(defvar *buffer-list-query-replace-after* nil)
(defvar *buffer-list-query-replace-source-window-cell* nil
  "Mutable source-window cell owned by the active marked-buffer query.")
(defvar *buffer-list-query-replace-recursive-buffer* nil
  "Source whose nested editor must retain the outer query undo boundary.")

(defmethod lem-vi-mode/core:buffer-state-disabled-hook :after
    ((state lem-vi-mode/states:insert) buffer)
  "Keep leaving Insert state inside a recursive query edit from sealing undo."
  (declare (ignore state))
  (when (eq buffer *buffer-list-query-replace-recursive-buffer*)
    (buffer-disable-undo-boundary buffer)))

(defparameter *buffer-list-query-replace-diff-buffer-name*
  "*Ibuffer Query Replace Diff*")
(defparameter *buffer-list-query-replace-diff-input-limit* (* 4 1024 1024))
(defparameter *buffer-list-query-replace-diff-output-limit* (* 16 1024 1024))

(declaim (ftype function buffer-list-query-replace-show-diff
                         capture-window-layout
                         dispose-window-layout
                         restore-window-layout
                         vundo-unified-diff))

(defun buffer-list-query-replace-read-args (regexp-p)
  (let* ((label (if regexp-p "Query replace regexp" "Query replace"))
         (before
           (prompt-for-string
            (if *buffer-list-query-replace-before*
                (format nil "~a (default ~s): "
                        label *buffer-list-query-replace-before*)
                (format nil "~a: " label)))))
    (when (zerop (length before))
      (unless *buffer-list-query-replace-before*
        (editor-error "Query-replace search string is empty"))
      (return-from buffer-list-query-replace-read-args
        (values *buffer-list-query-replace-before*
                *buffer-list-query-replace-after*)))
    (let ((after
            (prompt-for-string
             (format nil "~a ~s with: " label before))))
      (setf *buffer-list-query-replace-before* before
            *buffer-list-query-replace-after* after)
      (values before after))))

(defun buffer-list-query-replace-no-upper-case-p (string regexp-p)
  (let ((quoted-p nil))
    (loop :for character :across string
          :do (cond
                ((and regexp-p (char= character #\\))
                 (setf quoted-p (not quoted-p)))
                (t
                 (when (and (not quoted-p) (upper-case-p character))
                   (return-from
                     buffer-list-query-replace-no-upper-case-p nil))
                 (setf quoted-p nil)))))
  (not (and regexp-p
            (or (search "[:upper:]" string)
                (search "[:lower:]" string)))))

(defun buffer-list-query-replace-compile-replacement (replacement)
  (let ((pieces nil)
        (start 0)
        (length (length replacement)))
    (loop :for index :from 0 :below length
          :when (char= (aref replacement index) #\\)
            :do (when (< start index)
                  (push (subseq replacement start index) pieces))
                (incf index)
                (when (= index length)
                  (editor-error
                   "Invalid trailing backslash in Ibuffer regexp replacement"))
                (let ((directive (aref replacement index)))
                  (cond
                    ((char= directive #\\)
                     (push "\\" pieces))
                    ((char= directive #\&)
                     (push :whole-match pieces))
                    ((and (char<= #\1 directive)
                          (char<= directive #\9))
                     (push (cons :group (digit-char-p directive)) pieces))
                    ((char= directive #\#)
                     (push :replacement-count pieces))
                    ((char= directive #\?)
                     (push :edit-replacement pieces))
                    ((char= directive #\,)
                     (editor-error
                      "Unsupported Ibuffer regexp replacement directive: ~c~c"
                      #\\ directive))
                    (t
                     (editor-error
                      "Invalid Ibuffer regexp replacement directive: ~c~c"
                      #\\ directive))))
                (setf start (1+ index)))
    (when (< start length)
      (push (subseq replacement start) pieces))
    (nreverse pieces)))

(defun buffer-list-query-replace-expand-replacement
    (program matched-text captures replacement-count)
  (with-output-to-string (output)
    (dolist (piece program)
      (cond
        ((stringp piece)
         (write-string piece output))
        ((eq piece :whole-match)
         (write-string matched-text output))
        ((eq piece :replacement-count)
         (princ replacement-count output))
        ((eq piece :edit-replacement))
        ((and (consp piece) (eq (car piece) :group))
         (let ((capture (nth (1- (cdr piece)) captures)))
           (when capture
             (write-string capture output))))))))

(defun buffer-list-query-replace-first-edit-directive (replacement)
  (loop :with length := (length replacement)
        :for index :from 0 :below length
        :when (char= (aref replacement index) #\\)
          :do (incf index)
              (when (= index length)
                (return nil))
              (when (char= (aref replacement index) #\?)
                (return (1- index)))))

(defun buffer-list-query-replace-prompt-at
    (prompt initial-value input-position)
  (let ((lem-core::*prompt-after-activate-hook*
          (cons
           (cons
            (lambda ()
              (with-point ((point (buffer-start-point (current-buffer))
                                  :temporary))
                (character-offset point
                                  (+ (length prompt) input-position))
                (move-point (current-point) point)))
            0)
           lem-core::*prompt-after-activate-hook*)))
    (prompt-for-string prompt :initial-value initial-value)))

(defun buffer-list-query-replace-resolve-edit-directives (replacement)
  (loop :for position :=
          (buffer-list-query-replace-first-edit-directive replacement)
        :while position
        :do (setf replacement
                  (concatenate 'string
                               (subseq replacement 0 position)
                               (subseq replacement (+ position 2)))
                  replacement
                  (buffer-list-query-replace-prompt-at
                   "Edit replacement string: " replacement position))
        :finally (return replacement)))

(defun buffer-list-query-replace-case-action (matched-text)
  (let ((previous-word-p nil)
        (some-multiletter-word-p nil)
        (some-lowercase-p nil)
        (some-uppercase-p nil)
        (some-nonuppercase-initial-p nil))
    (loop :for character :across matched-text
          :do (cond
                ((lower-case-p character)
                 (setf some-lowercase-p t)
                 (if previous-word-p
                     (setf some-multiletter-word-p t)
                     (setf some-nonuppercase-initial-p t)))
                ((upper-case-p character)
                 (setf some-uppercase-p t)
                 (when previous-word-p
                   (setf some-multiletter-word-p t)))
                ((not previous-word-p)
                 (setf some-nonuppercase-initial-p t)))
              (setf previous-word-p (syntax-word-char-p character)))
    (cond
      ((and (not some-lowercase-p) some-multiletter-word-p)
       :all-caps)
      ((and (not some-nonuppercase-initial-p) some-multiletter-word-p)
       :initial-caps)
      ((and (not some-nonuppercase-initial-p) some-uppercase-p)
       :all-caps)
      (t nil))))

(defun buffer-list-query-replace-upcase-initials (string)
  (let ((result (copy-seq string))
        (previous-word-p nil))
    (loop :for index :from 0 :below (length result)
          :for character := (aref result index)
          :for word-p := (syntax-word-char-p character)
          :do (when (and word-p (not previous-word-p))
                (setf (aref result index) (char-upcase character)))
              (setf previous-word-p word-p))
    result))

(defun buffer-list-query-replace-transfer-case
    (replacement matched-text case-fold-p)
  (if (not case-fold-p)
      replacement
      (case (buffer-list-query-replace-case-action matched-text)
        (:all-caps (string-upcase replacement))
        (:initial-caps
         (buffer-list-query-replace-upcase-initials replacement))
        (otherwise replacement))))

(defun buffer-list-query-replace-preflight (buffers)
  (unless buffers
    (editor-error "No buffer on this Ibuffer row"))
  (dolist (buffer buffers)
    (unless (buffer-list-multi-isearch-live-buffer-p buffer)
      (editor-error "Ibuffer query-replace source was killed"))
    (when (buffer-read-only-p buffer)
      (editor-error "Ibuffer query-replace source is read-only: ~a"
                    (completion-path-display-string (buffer-name buffer))))))

(defun buffer-list-query-replace-regexp-scanner
    (pattern case-fold-p)
  (let ((scanner
          (handler-case
              (cl-ppcre:create-scanner
               pattern :case-insensitive-mode case-fold-p)
            (error () nil))))
    (unless scanner
      (editor-error "Invalid Ibuffer query-replace regexp"))
    scanner))

(defstruct buffer-list-query-replace-entry
  start
  end
  original
  captures
  capture-ranges
  replacement
  replaced-p
  counted-p)

(defun buffer-list-query-replace-delete-entry (entry)
  (when entry
    (dolist (range (buffer-list-query-replace-entry-capture-ranges entry))
      (when range
        (ignore-errors (delete-point (car range)))
        (ignore-errors (delete-point (cdr range)))))
    (ignore-errors
      (delete-point (buffer-list-query-replace-entry-start entry)))
    (ignore-errors
      (delete-point (buffer-list-query-replace-entry-end entry)))))

(defun buffer-list-query-replace-delete-entries (entries)
  (dolist (entry entries)
    (buffer-list-query-replace-delete-entry entry)))

(defun buffer-list-query-replace-make-entry
    (start end captures &optional capture-ranges)
  (make-buffer-list-query-replace-entry
   :start (copy-point start :right-inserting)
   :end (copy-point end :left-inserting)
   :original (points-to-string start end)
   :captures captures
   :capture-ranges capture-ranges))

(defun buffer-list-query-replace-make-capture-ranges
    (line-point capture-starts capture-ends)
  (when capture-starts
    (map 'list
         (lambda (capture-start capture-end)
           (when capture-start
             (with-point ((start line-point :temporary)
                          (end line-point :temporary))
               (line-start start)
               (line-start end)
               (character-offset start capture-start)
               (character-offset end capture-end)
               (cons (copy-point start :right-inserting)
                     (copy-point end :right-inserting)))))
         capture-starts capture-ends)))

(defun buffer-list-query-replace-entry-live-captures (entry)
  (let ((ranges (buffer-list-query-replace-entry-capture-ranges entry)))
    (if ranges
        (mapcar
         (lambda (range)
           (when range
             (points-to-string (car range) (cdr range))))
         ranges)
        (buffer-list-query-replace-entry-captures entry))))

(defun buffer-list-query-replace-next-regexp-entry (cursor scanner goal)
  "Move CURSOR to the next match end and return its stable edit entry.

Lem's public regexp search returns the match end and captures, but not the
match start.  A second backward search cannot recover that start reliably for
zero-width or overlapping regular expressions, so retain both bounds from the
same CL-PPCRE scan."
  (loop
    (let ((line (line-string cursor)))
      (multiple-value-bind (start end capture-starts capture-ends)
          (cl-ppcre:scan scanner line
                        :start (point-charpos cursor)
                        :real-start-pos 0)
        (when start
          (with-point ((match-start cursor :temporary)
                       (match-end cursor :temporary))
            (line-start match-start)
            (line-start match-end)
            (character-offset match-start start)
            (character-offset match-end end)
            (when (point< goal match-end)
              (return nil))
            (move-point cursor match-end)
            (return
              (buffer-list-query-replace-make-entry
               match-start match-end
               (when capture-starts
                 (map 'list
                      (lambda (capture-start capture-end)
                        (when capture-start
                          (subseq line capture-start capture-end)))
                      capture-starts capture-ends))
               (buffer-list-query-replace-make-capture-ranges
                match-start capture-starts capture-ends)))))))
    (unless (line-offset cursor 1)
      (return nil))
    (line-start cursor)))

(defun buffer-list-query-replace-entry-empty-p (entry)
  (zerop (length (buffer-list-query-replace-entry-original entry))))

(defun buffer-list-query-replace-entry-current-text (entry)
  (points-to-string (buffer-list-query-replace-entry-start entry)
                    (buffer-list-query-replace-entry-end entry)))

(defun buffer-list-query-replace-entry-expected-text (entry)
  (if (buffer-list-query-replace-entry-replaced-p entry)
      (buffer-list-query-replace-entry-replacement entry)
      (buffer-list-query-replace-entry-original entry)))

(defun buffer-list-query-replace-entry-set-text (entry replacement replaced-p)
  (let ((expected (buffer-list-query-replace-entry-expected-text entry)))
    (unless (string= expected
                     (buffer-list-query-replace-entry-current-text entry))
      (editor-error "Ibuffer query-replace match changed during prompting"))
    (unless (string= expected replacement)
      (let* ((buffer
               (point-buffer (buffer-list-query-replace-entry-start entry)))
             (outer-group
               (lem/buffer/internal::buffer-%active-change-group buffer)))
        (flet ((mutate ()
                 (delete-between-points
                  (buffer-list-query-replace-entry-start entry)
                  (buffer-list-query-replace-entry-end entry))
                 (with-point
                     ((insertion
                        (buffer-list-query-replace-entry-start entry)
                        :temporary))
                   (insert-string insertion replacement))))
          (if outer-group
              (mutate)
              (let ((group (buffer-prepare-change-group buffer)))
                (handler-case
                    (progn
                      (mutate)
                      (buffer-accept-change-group group))
                  (error (condition)
                    (when (buffer-change-group-active-p group)
                      (ignore-errors (buffer-cancel-change-group group)))
                    (error condition))))))))
    (setf (buffer-list-query-replace-entry-replacement entry)
          (and replaced-p replacement)
          (buffer-list-query-replace-entry-replaced-p entry) replaced-p
          (buffer-list-query-replace-entry-counted-p entry) replaced-p)
    entry))

(defun buffer-list-query-replace-entry-replace (entry replacement)
  (unless (buffer-list-query-replace-entry-replaced-p entry)
    (buffer-list-query-replace-entry-set-text entry replacement t)))

(defun buffer-list-query-replace-entry-undo (entry)
  (when (buffer-list-query-replace-entry-replaced-p entry)
    (buffer-list-query-replace-entry-set-text
     entry (buffer-list-query-replace-entry-original entry) nil)))

(defun buffer-list-query-replace-effective-replacement
    (entry raw-replacement replacement-program replacement-count
     case-fold-p exact-case-p)
  (let* ((matched-text (buffer-list-query-replace-entry-original entry))
         (expanded
           (if replacement-program
               (buffer-list-query-replace-expand-replacement
                replacement-program matched-text
                (buffer-list-query-replace-entry-live-captures entry)
                replacement-count)
               raw-replacement)))
    (if exact-case-p
        expanded
        (buffer-list-query-replace-transfer-case
         expanded matched-text case-fold-p))))

(defun buffer-list-query-replace-final-replacement
    (entry raw-replacement replacement-program replacement-count
     case-fold-p regexp-p exact-case-p)
  (let* ((resolved-raw
           (if (and regexp-p
                    (member :edit-replacement replacement-program :test #'eq))
               (buffer-list-query-replace-resolve-edit-directives
                raw-replacement)
               raw-replacement))
         (resolved-program
           (and regexp-p
                (buffer-list-query-replace-compile-replacement resolved-raw))))
    (buffer-list-query-replace-effective-replacement
     entry resolved-raw resolved-program replacement-count
     case-fold-p exact-case-p)))

(defun buffer-list-query-replace-recursive-command-loop ()
  "Run ordinary editor commands until GNU's `exit-recursive-edit' key."
  (let ((exit-key (first (lem-core::parse-keyspec "C-M-c"))))
    (lem-core::do-command-loop (:interactive t)
      (incf lem-core::*command-loop-counter*)
      (redraw-display)
      (let ((key (read-key)))
        (when (lem-core::keys-equal-p key exit-key)
          (return))
        (unread-key key)
        (lem-core::command-loop-body)
        (lem-core::fix-current-buffer-if-broken)))))

(defun buffer-list-query-replace-refresh-after-recursive-edit (entry)
  "Adopt live marker text after recursive editing of ENTRY."
  (let ((text (buffer-list-query-replace-entry-current-text entry)))
    (if (buffer-list-query-replace-entry-replaced-p entry)
        (setf (buffer-list-query-replace-entry-replacement entry) text)
        (setf (buffer-list-query-replace-entry-original entry) text)))
  entry)

(defun buffer-list-query-replace-recursive-edit (entry)
  "Edit ENTRY in a nested command loop, then restore the query layout."
  (let* ((buffer (point-buffer (buffer-list-query-replace-entry-start entry)))
         (configuration (capture-window-layout))
         (return-point (copy-point (current-point) :right-inserting))
         (restored-p nil))
    (unless configuration
      (delete-point return-point)
      (editor-error "Cannot record the query-replace window layout"))
    (unwind-protect
         (let ((*buffer-list-query-replace-recursive-buffer* buffer))
           (move-point (current-point)
                       (buffer-list-query-replace-entry-start entry))
           (message "Recursive edit; type C-M-c to resume query replace")
           (buffer-list-query-replace-recursive-command-loop))
      (when (and (not (deleted-buffer-p buffer))
                 (alive-point-p return-point))
        (setf restored-p
              (handler-case (restore-window-layout configuration)
                (error () nil)))
        (unless restored-p
          (switch-to-buffer buffer))
        (move-point (current-point) return-point)
        (when *buffer-list-query-replace-source-window-cell*
          (setf (car *buffer-list-query-replace-source-window-cell*)
                (current-window))))
      (dispose-window-layout configuration)
      (delete-point return-point))
    (when (deleted-buffer-p buffer)
      (editor-error "Ibuffer query-replace source was killed during recursive edit"))
    (unless restored-p
      (message "Recursive edit ended; the prior window layout could not be restored"))
    (buffer-list-query-replace-refresh-after-recursive-edit entry)))

(defun buffer-list-query-replace-response
    (before displayed-replacement raw-replacement)
  (loop
    :for response :=
      (prompt-for-character
       (format nil "Replace ~s with ~s [y/n/!/q/./,/^/u/U/e/E/d/C-r/C-w]"
               before displayed-replacement))
    :do
       (cond
         ((or (char-equal response #\y)
              (char= response #\Space))
          (return :replace))
         ((or (char-equal response #\n)
              (char= response #\Backspace)
              (= (char-code response) 127))
          (return :skip))
         ((char= response #\!)
          (return :replace-rest))
         ((or (char-equal response #\q)
              (char= response #\Newline)
              (char= response #\Return)
              (= (char-code response) 27))
          (return :exit))
         ((char= response #\.)
          (return :replace-and-exit))
         ((char= response #\,)
          (return :replace-and-show))
         ((char= response #\^)
          (return :backup))
         ((char= response #\u)
          (return :undo))
         ((char= response #\U)
          (return :undo-all))
         ((char= response #\d)
          (return :diff))
         ((= (char-code response) 18)
          (return :recursive-edit))
         ((= (char-code response) 23)
          (return :delete-and-edit))
         ((char= response #\e)
          (return
            (cons :edit
                  (prompt-for-string "Edit replacement string: "
                                     :initial-value raw-replacement))))
         ((char= response #\E)
          (return
            (cons :edit-exact
                  (prompt-for-string "Edit replacement string (exact case): "
                                     :initial-value raw-replacement))))
         ((char= response #\?)
          (message
           "y/Space replace; n/Backspace skip; , replace and stay; ! rest; q/Return exit; . replace and exit; ^ back; u/U undo; e/E edit replacement; d diff; C-r recursive edit; C-w delete and edit"))
         (t
          (message "Unsupported query-replace response: ~s" response)))))

(defun buffer-list-query-replace-buffer
    (buffer before after forward-function backward-function case-fold-p
     regexp-p replacement-program &optional regexp-scanner automatic-p
                                           output-character-limit)
  (with-current-buffer buffer
    (let ((lem/isearch::*isearch-search-forward-function* forward-function)
          (lem/isearch::*isearch-search-backward-function* backward-function)
          (replace-rest-p automatic-p)
          (replacement-count 0)
          (raw-replacement after)
          (current-program replacement-program)
          (history nil)
          (current-entry nil)
          (advance-before-search-p nil)
          (last-was-replace-and-show-p nil)
          (query-change-group nil)
          (completed-p nil)
          (undo-boundary-enabled-p
           (lem/buffer/internal::buffer-enable-undo-boundary-p buffer)))
      (buffer-undo-boundary buffer)
      ;; Character and string prompts run their own editor commands.  Keep
      ;; those command boundaries from splitting this source-buffer operation;
      ;; the explicit boundary in the outer unwind path seals the complete
      ;; query as one undo unit.
      (when undo-boundary-enabled-p
        (buffer-disable-undo-boundary buffer))
      (unwind-protect
           (unwind-protect
                (prog1
                    (unwind-protect
                         (with-point ((cursor (buffer-start-point buffer)
                                              :left-inserting)
                                      (goal (buffer-end-point buffer)
                                            :right-inserting))
                  (lem/isearch::highlight-region cursor goal before)
                  (loop
                   (unless current-entry
                     (when advance-before-search-p
                       (setf advance-before-search-p nil)
                       (unless (and (point< cursor goal)
                                    (character-offset cursor 1))
                         (return replacement-count)))
                     (if regexp-scanner
                         (setf current-entry
                               (buffer-list-query-replace-next-regexp-entry
                                cursor regexp-scanner goal))
                         (let ((search-values
                                (multiple-value-list
                                 (funcall forward-function cursor before))))
                           (unless (first search-values)
                             (return replacement-count))
                           (when (point< goal cursor)
                             (return replacement-count))
                           (with-point ((end cursor :right-inserting))
                             (unless (funcall backward-function cursor before)
                               (error
                                "Ibuffer query-replace could not recover match start"))
                             (with-point ((start cursor :right-inserting))
                               (setf current-entry
                                     (buffer-list-query-replace-make-entry
                                      start end (rest search-values)))))))
                     (unless current-entry
                       (return replacement-count)))
                   (let* ((replacement
                           (buffer-list-query-replace-effective-replacement
                            current-entry raw-replacement current-program
                            replacement-count case-fold-p nil))
                          (response
                           (if replace-rest-p
                               :replace
                               (save-excursion
                                 (move-point
                                  (current-point)
                                  (buffer-list-query-replace-entry-end
                                   current-entry))
                                 (lem/isearch::activate-current-highlight cursor)
                                 (redraw-display)
                                 (buffer-list-query-replace-response
                                  before replacement raw-replacement)))))
                     (cond
                       ((consp response)
                        (let* ((exact-case-p (eq (car response) :edit-exact))
                               (edited (cdr response))
                               (edited-program
                                (and regexp-p
                                     (buffer-list-query-replace-compile-replacement
                                      edited))))
                          (setf raw-replacement edited
                                current-program edited-program)
                          (unless (buffer-list-query-replace-entry-replaced-p
                                   current-entry)
                            (buffer-list-query-replace-entry-replace
                             current-entry
                             (buffer-list-query-replace-final-replacement
                              current-entry edited edited-program
                              replacement-count case-fold-p regexp-p
                              exact-case-p))
                            (incf replacement-count))
                          (move-point
                           cursor
                           (buffer-list-query-replace-entry-end current-entry))
                     (setf advance-before-search-p
                           (buffer-list-query-replace-entry-empty-p
                            current-entry))
                     (push current-entry history)
                     (setf current-entry nil
                           last-was-replace-and-show-p nil)))
                  ((eq response :skip)
                   (move-point
                    cursor (buffer-list-query-replace-entry-end current-entry))
                        (setf advance-before-search-p
                         (buffer-list-query-replace-entry-empty-p current-entry))
                   (push current-entry history)
                   (setf current-entry nil
                         last-was-replace-and-show-p nil))
                  ((eq response :exit)
                   (return replacement-count))
                  ((eq response :backup)
                   (cond
                     ;; GNU records the comma replacement immediately.  Its
                     ;; first backup therefore revisits that same live match.
                     (last-was-replace-and-show-p
                      (setf last-was-replace-and-show-p nil))
                     (history
                      (buffer-list-query-replace-delete-entry current-entry)
                      (setf current-entry (pop history))
                      (move-point
                       cursor
                       (buffer-list-query-replace-entry-end current-entry))
                      (setf advance-before-search-p nil))
                     (t
                      (message "No previous match"))))
                  ((member response '(:recursive-edit :delete-and-edit)
                           :test #'eq)
                   ;; Ordinary commands in the nested command loop must be
                   ;; part of the same undo unit as replacements made before
                   ;; and after the recursive edit.
                   (unless query-change-group
                     (setf query-change-group
                           (buffer-prepare-change-group buffer)))
                   (when (eq response :delete-and-edit)
                     (buffer-list-query-replace-entry-set-text
                      current-entry "" t)
                     ;; GNU records this as an edited occurrence, but does not
                     ;; add it to the replacement count.
                     (setf (buffer-list-query-replace-entry-counted-p
                            current-entry)
                           nil))
                   (buffer-list-query-replace-recursive-edit current-entry)
                   (move-point
                    cursor (buffer-list-query-replace-entry-end current-entry))
                   (setf advance-before-search-p nil
                         last-was-replace-and-show-p nil))
                  ((eq response :undo)
                   (cond
                     ((buffer-list-query-replace-entry-replaced-p current-entry)
                      (let ((counted-p
                              (buffer-list-query-replace-entry-counted-p
                               current-entry)))
                        (buffer-list-query-replace-entry-undo current-entry)
                        (when counted-p
                          (decf replacement-count)))
                      (setf last-was-replace-and-show-p nil)
                      (move-point
                       cursor
                       (buffer-list-query-replace-entry-end current-entry)))
                          ((position-if
                            #'buffer-list-query-replace-entry-replaced-p history)
                           (let* ((index
                                   (position-if
                                    #'buffer-list-query-replace-entry-replaced-p
                                    history))
                                  (target (nth index history))
                                  (newer (subseq history 0 index)))
                             (buffer-list-query-replace-delete-entries newer)
                             (setf history (nthcdr (1+ index) history))
                             (let ((counted-p
                                     (buffer-list-query-replace-entry-counted-p
                                      target)))
                               (buffer-list-query-replace-entry-undo target)
                               (when counted-p
                                 (decf replacement-count)))
                        (buffer-list-query-replace-delete-entry current-entry)
                        (setf current-entry target
                              advance-before-search-p nil
                              last-was-replace-and-show-p nil)
                        (move-point
                         cursor
                         (buffer-list-query-replace-entry-end current-entry))))
                          (t
                           (message "Nothing to undo"))))
                       ((eq response :undo-all)
                        (let* ((entries (cons current-entry history))
                               (replaced
                                (remove-if-not
                                 #'buffer-list-query-replace-entry-replaced-p
                                 entries)))
                          (if replaced
                              (let ((oldest (car (last replaced))))
                                (decf replacement-count
                                      (count-if
                                       #'buffer-list-query-replace-entry-counted-p
                                       replaced))
                                (dolist (entry replaced)
                                  (buffer-list-query-replace-entry-undo entry))
                                (dolist (entry entries)
                                  (unless (eq entry oldest)
                                    (buffer-list-query-replace-delete-entry entry)))
                           (setf history nil
                                 current-entry oldest
                                 advance-before-search-p nil
                                 last-was-replace-and-show-p nil)
                           (move-point
                            cursor
                            (buffer-list-query-replace-entry-end current-entry)))
                              (message "Nothing to undo"))))
                       ((eq response :diff)
                        (buffer-list-query-replace-show-diff
                         buffer before raw-replacement case-fold-p regexp-p
                         current-program regexp-scanner))
                       ((eq response :replace-and-show)
                        (unless (buffer-list-query-replace-entry-replaced-p
                                 current-entry)
                          (buffer-list-query-replace-entry-replace
                           current-entry
                           (buffer-list-query-replace-final-replacement
                            current-entry raw-replacement current-program
                            replacement-count case-fold-p regexp-p nil))
                     (incf replacement-count))
                   (move-point
                    cursor (buffer-list-query-replace-entry-end current-entry))
                   (setf last-was-replace-and-show-p t))
                       ((member response
                                '(:replace :replace-rest :replace-and-exit)
                                :test #'eq)
                        (when (eq response :replace-rest)
                          (setf replace-rest-p t))
                        (unless (buffer-list-query-replace-entry-replaced-p
                                 current-entry)
                          (let ((final-replacement
                                  (buffer-list-query-replace-final-replacement
                                   current-entry raw-replacement current-program
                                   replacement-count case-fold-p regexp-p nil)))
                            (when output-character-limit
                              (let ((projected-length
                                      (+ (- (position-at-point
                                             (buffer-end-point buffer))
                                            (position-at-point
                                             (buffer-start-point buffer)))
                                         (- (length final-replacement)
                                            (length
                                             (buffer-list-query-replace-entry-original
                                              current-entry))))))
                                (when (> projected-length
                                         output-character-limit)
                                  (editor-error
                                   "Ibuffer query-replace preview exceeds ~d characters"
                                   output-character-limit))))
                            (buffer-list-query-replace-entry-replace
                             current-entry final-replacement)
                            (incf replacement-count)))
                        (when (eq response :replace-and-exit)
                          (return replacement-count))
                        (move-point
                         cursor (buffer-list-query-replace-entry-end current-entry))
                        (setf advance-before-search-p
                         (buffer-list-query-replace-entry-empty-p current-entry))
                   (push current-entry history)
                   (setf current-entry nil
                         last-was-replace-and-show-p nil))))))
                      (lem/isearch::isearch-reset-overlays buffer)
                      (buffer-list-query-replace-delete-entry current-entry)
                      (buffer-list-query-replace-delete-entries history))
                  (setf completed-p t))
             (when (and query-change-group
                        (buffer-change-group-active-p query-change-group))
               (if completed-p
                   (buffer-accept-change-group query-change-group)
                   (ignore-errors
                     (buffer-cancel-change-group query-change-group)))))
        (when undo-boundary-enabled-p
          (buffer-enable-undo-boundary buffer))
        (buffer-undo-boundary buffer)))))

(defun buffer-list-query-replace-preview-text
    (source-text before after case-fold-p regexp-p replacement-program scanner)
  (when (> (length source-text) *buffer-list-query-replace-diff-input-limit*)
    (editor-error "Ibuffer query-replace diff input exceeds ~d characters"
                  *buffer-list-query-replace-diff-input-limit*))
  (let ((preview (make-buffer nil :temporary t :enable-undo-p t)))
    (unwind-protect
         (progn
           (insert-string (buffer-start-point preview) source-text)
           (if scanner
               (flet ((forward (point _pattern &optional limit)
                        (declare (ignore _pattern))
                        (search-forward-regexp point scanner limit))
                      (backward (point _pattern &optional limit)
                        (declare (ignore _pattern))
                        (search-backward-regexp point scanner limit)))
                 (buffer-list-query-replace-buffer
                  preview before after #'forward #'backward
                  case-fold-p regexp-p replacement-program scanner t
                  *buffer-list-query-replace-diff-output-limit*))
               (let ((lem/buffer/internal::*case-fold-search*
                       (not case-fold-p)))
                 (buffer-list-query-replace-buffer
                  preview before after #'search-forward #'search-backward
                  case-fold-p regexp-p nil nil t
                  *buffer-list-query-replace-diff-output-limit*)))
           (points-to-string (buffer-start-point preview)
                             (buffer-end-point preview)))
      (ignore-errors (delete-buffer preview)))))

(defun buffer-list-query-replace-show-diff
    (buffer before after case-fold-p regexp-p replacement-program scanner)
  (let ((source-length
          (- (position-at-point (buffer-end-point buffer))
             (position-at-point (buffer-start-point buffer)))))
    (when (> source-length *buffer-list-query-replace-diff-input-limit*)
      (editor-error "Ibuffer query-replace diff input exceeds ~d characters"
                    *buffer-list-query-replace-diff-input-limit*)))
  (let* ((source-text
           (points-to-string (buffer-start-point buffer)
                             (buffer-end-point buffer)))
         (preview-text
           (buffer-list-query-replace-preview-text
            source-text before after case-fold-p regexp-p
            replacement-program scanner))
         (label (buffer-name buffer))
         (text
           (vundo-unified-diff
            source-text preview-text
            (format nil "~a (current)" label)
            (format nil "~a (replace)" label)))
         (diff-buffer
           (make-buffer *buffer-list-query-replace-diff-buffer-name*
                        :enable-undo-p nil))
         (source-window (current-window)))
    (buffer-disable-undo diff-buffer)
    (with-buffer-read-only diff-buffer nil
      (erase-buffer diff-buffer)
      (insert-string (buffer-start-point diff-buffer) text)
      (buffer-start (buffer-point diff-buffer)))
    (change-buffer-mode diff-buffer 'buffer-list-diff-mode)
    (buffer-mark-saved diff-buffer)
    (setf (buffer-read-only-p diff-buffer) t)
    (pop-to-buffer diff-buffer)
    (unless (and source-window
                 (not (deleted-window-p source-window))
                 (eq (window-buffer source-window) buffer))
      (editor-error "Cannot display Ibuffer query-replace diff safely"))
    (setf (current-window) source-window)
    (redraw-display)
    diff-buffer))

(defun buffer-list-query-replace-restore-picker
    (component source-window source-buffer source-point source-view-point
     focused-buffer focused-index)
  (unless (and source-window (not (deleted-window-p source-window)))
    (editor-error "Ibuffer source window was deleted during query-replace"))
  (setf (current-window) source-window)
  (when (buffer-list-multi-isearch-live-buffer-p source-buffer)
    (switch-to-buffer source-buffer)
    (when (alive-point-p source-point)
      (move-point (current-point) source-point))
    (when (alive-point-p source-view-point)
      (move-point (window-view-point source-window) source-view-point)))
  (buffer-list-reset-visible-items component)
  (lem/multi-column-list:display component)
  (buffer-list-filter-input-mode nil)
  (buffer-list-picker-mode t)
  (unless (buffer-list-focus-buffer component focused-buffer)
    (buffer-list-focus-index component focused-index)))

(defun buffer-list-query-replace-run (regexp-p)
  (let* ((component (lem/multi-column-list::current-multi-column-list))
         (focused-buffer (buffer-list-current-buffer component))
         (focused-index
           (or (position (buffer-list-current-item component)
                         (lem/multi-column-list::multi-column-list-items component)
                         :test #'eq)
               0))
         (buffers (buffer-list-action-buffers component))
         (source-window (buffer-list-source-window component))
         (source-buffer (window-buffer source-window))
         (source-point (copy-point (window-point source-window) :temporary))
         (source-view-point
           (copy-point (window-view-point source-window) :temporary)))
    (buffer-list-query-replace-preflight buffers)
    (multiple-value-bind (before after)
        (buffer-list-query-replace-read-args regexp-p)
      (let* ((*buffer-list-query-replace-source-window-cell*
               (list source-window))
             (case-fold-p
               (buffer-list-query-replace-no-upper-case-p before regexp-p))
             (scanner
               (and regexp-p
                    (buffer-list-query-replace-regexp-scanner
                     before case-fold-p)))
             (replacement-program
               (and regexp-p
                    (buffer-list-query-replace-compile-replacement after)))
            (replacement-count 0)
            (processed-count 0))
        ;; Hide the floating chooser while matches are displayed.  The same
        ;; component is rebuilt in the unwind path with marks and focus intact.
        (lem/multi-column-list:quit component)
        (unwind-protect
            (dolist (buffer buffers)
              (unless (buffer-list-multi-isearch-live-buffer-p buffer)
                (editor-error "Ibuffer query-replace source was killed"))
              (with-current-window
                  (car *buffer-list-query-replace-source-window-cell*)
                (switch-to-buffer buffer)
                (buffer-start (current-point))
                (incf replacement-count
                      (if scanner
                          (flet ((forward (point _pattern &optional limit)
                                   (declare (ignore _pattern))
                                   (search-forward-regexp point scanner limit))
                                 (backward (point _pattern &optional limit)
                                   (declare (ignore _pattern))
                                   (search-backward-regexp point scanner limit)))
                            (buffer-list-query-replace-buffer
                             buffer before after #'forward #'backward
                             case-fold-p regexp-p replacement-program scanner))
                          (let ((lem/buffer/internal::*case-fold-search*
                                  (not case-fold-p)))
                            (buffer-list-query-replace-buffer
                             buffer before after
                             #'search-forward #'search-backward
                             case-fold-p regexp-p nil))))
                (incf processed-count)))
          (buffer-list-query-replace-restore-picker
           component (car *buffer-list-query-replace-source-window-cell*)
           source-buffer source-point source-view-point
           focused-buffer focused-index))
        (message "Query replace finished; ~d replacement~:p in ~d buffer~:p"
                 replacement-count processed-count)))))

(define-command lem-yath-buffer-list-query-replace () ()
  (buffer-list-query-replace-run nil))

(define-command lem-yath-buffer-list-query-replace-regexp () ()
  (buffer-list-query-replace-run t))

(defun buffer-list-move-to-marked (component direction)
  (let* ((items (lem/multi-column-list::multi-column-list-items component))
         (current (buffer-list-current-item component))
         (start (or (position current items :test #'eq) 0))
         (length (length items)))
    (when (zerop length)
      (editor-error "No marked buffers"))
    (loop :for offset :from 1 :to length
          :for index := (mod (+ start (* direction offset)) length)
          :for item := (elt items index)
          :when (buffer-list-ordinary-marked-item-p component item)
            :do (buffer-list-focus-index component index)
                (return-from buffer-list-move-to-marked item))
    (editor-error "No ordinarily marked buffers")))

(define-command lem-yath-buffer-list-next-marked () ()
  (buffer-list-move-to-marked
   (lem/multi-column-list::current-multi-column-list) 1))

(define-command lem-yath-buffer-list-previous-marked () ()
  (buffer-list-move-to-marked
   (lem/multi-column-list::current-multi-column-list) -1))

(defun buffer-list-action-buffers (component)
  (mapcar (lambda (item)
            (buffer-list-entry-buffer (buffer-list-item-entry item)))
          (buffer-list-action-items component)))

(defun buffer-list-refresh-after-buffer-mutation
    (component focused-buffer focused-index &key resort)
  (when resort
    (buffer-list-sort-all-items component))
  (buffer-list-refresh component :recompute-columns t)
  (unless (buffer-list-focus-buffer component focused-buffer)
    (buffer-list-focus-index component focused-index)))

(defun buffer-list-set-modified (buffer)
  "Mark BUFFER dirty without manufacturing an edit in the retained undo tree."
  (let ((slot
          (find "%UNDO-TREE-UNTRACKED-DIRTY-P"
                (sb-mop:class-slots (class-of buffer))
                :key (lambda (definition)
                       (symbol-name (sb-mop:slot-definition-name definition)))
                :test #'string=)))
    (unless slot
      (error "Lem buffer class has no modification-state slot"))
    (setf (slot-value buffer (sb-mop:slot-definition-name slot)) t)))

(define-command lem-yath-buffer-list-toggle-modified () ()
  (let* ((component (lem/multi-column-list::current-multi-column-list))
         (focused-buffer (buffer-list-current-buffer component))
         (focused-index
           (or (position (buffer-list-current-item component)
                         (lem/multi-column-list::multi-column-list-items component)
                         :test #'eq)
               0)))
    (dolist (buffer (buffer-list-action-buffers component))
      (if (buffer-modified-p buffer)
          (buffer-unmark buffer)
          (buffer-list-set-modified buffer)))
    (buffer-list-refresh-after-buffer-mutation
     component focused-buffer focused-index)))

(define-command lem-yath-buffer-list-toggle-read-only () ()
  (let* ((component (lem/multi-column-list::current-multi-column-list))
         (focused-buffer (buffer-list-current-buffer component))
         (focused-index
           (or (position (buffer-list-current-item component)
                         (lem/multi-column-list::multi-column-list-items component)
                         :test #'eq)
               0)))
    (dolist (buffer (buffer-list-action-buffers component))
      (setf (buffer-read-only-p buffer)
            (not (buffer-read-only-p buffer))))
    (buffer-list-refresh-after-buffer-mutation
     component focused-buffer focused-index)))

(defun buffer-list-set-lock-from-argument (buffer argument)
  "Apply Emacs minor-mode prefix semantics to BUFFER's lock."
  (setf (variable-value 'buffer-lock-mode :buffer buffer)
        (if (integerp argument)
            (plusp argument)
            (not (buffer-list-buffer-locked-p buffer)))))

(define-command lem-yath-buffer-lock-mode (argument) (:universal-nil)
  "Toggle GNU Emacs-style kill-and-exit locking for the current buffer."
  (buffer-list-set-lock-from-argument (current-buffer) argument)
  (message "Buffer ~s is ~:[unlocked~;locked~]"
           (buffer-name (current-buffer))
           (buffer-list-buffer-locked-p (current-buffer))))

(define-command lem-yath-buffer-list-toggle-lock (argument) (:universal-nil)
  "Toggle lock state in ordinary-marked buffers or the current row."
  (let* ((component (lem/multi-column-list::current-multi-column-list))
         (focused-buffer (buffer-list-current-buffer component))
         (focused-index
           (or (position (buffer-list-current-item component)
                         (lem/multi-column-list::multi-column-list-items component)
                         :test #'eq)
               0))
         (buffers (buffer-list-action-buffers component)))
    (dolist (buffer buffers)
      (buffer-list-set-lock-from-argument buffer argument))
    (buffer-list-refresh-after-buffer-mutation
     component focused-buffer focused-index)
    (message "Toggled lock status in ~d buffer~:p" (length buffers))))

(defun buffer-list-emacs-unique-base-name (buffer)
  (let* ((name (buffer-name buffer))
         (file-name
           (alexandria:when-let ((filename (buffer-filename buffer)))
             (ignore-errors (file-namestring filename)))))
    (multiple-value-bind (start end)
        (cl-ppcre:scan "<[0-9]+>$" name)
      (declare (ignore end))
      (if (and start
               (not (and file-name (string= name file-name))))
          (subseq name 0 start)
          name))))

(defun buffer-list-emacs-unique-name (buffer)
  (let ((base-name (buffer-list-emacs-unique-base-name buffer)))
    (if (null (get-buffer base-name))
        base-name
        (loop :for suffix :from 2
              :for name := (format nil "~a<~d>" base-name suffix)
              :unless (get-buffer name)
                :return name))))

(define-command lem-yath-buffer-list-rename-uniquely () ()
  (let* ((component (lem/multi-column-list::current-multi-column-list))
         (focused-buffer (buffer-list-current-buffer component))
         (focused-index
           (or (position (buffer-list-current-item component)
                         (lem/multi-column-list::multi-column-list-items component)
                         :test #'eq)
               0)))
    (dolist (buffer (buffer-list-action-buffers component))
      (buffer-rename buffer (buffer-list-emacs-unique-name buffer)))
    (buffer-list-refresh-after-buffer-mutation
     component focused-buffer focused-index :resort t)))

(define-command lem-yath-buffer-list-bury () ()
  (let* ((component (lem/multi-column-list::current-multi-column-list))
         (buffer (buffer-list-require-current-buffer component))
         (index
           (or (position (buffer-list-current-item component)
                         (lem/multi-column-list::multi-column-list-items component)
                         :test #'eq)
               0)))
    (bury-buffer buffer)
    (buffer-list-rebuild-snapshot
     component :preserve-focused-buffer-p nil :focus-index index)))

(defun buffer-list-revert-buffer (buffer)
  (with-current-buffer buffer
    (alexandria:if-let
        ((revert (lem-core/commands/file:revert-buffer-function buffer)))
      (funcall revert buffer)
      (if (buffer-filename buffer)
          (lem-core/commands/file:sync-buffer-with-file-content buffer)
          (error "Buffer ~a cannot be reverted" (buffer-name buffer)))))
  (alexandria:when-let ((path (buffer-file-path-key buffer)))
    (set-buffer-file-state
     buffer path (stable-buffer-file-signature buffer path)))
  t)

(defun buffer-list-confirm-revert (buffers)
  (prompt-for-y-or-n-p
   (if (= 1 (length buffers))
       (format nil "Really revert buffer ~a?" (buffer-name (first buffers)))
       (format nil "Really revert ~d buffers?" (length buffers)))))

(defparameter *buffer-list-diff-buffer-name* "*Ibuffer Diff*")
(defparameter *buffer-list-diff-input-limit* (* 16 1024 1024))

(defun buffer-list-diff-file-text (pathname)
  (with-open-file (stream pathname
                          :direction :input
                          :external-format :utf-8
                          :if-does-not-exist nil)
    (unless stream
      (editor-error "File does not exist: ~a" pathname))
    (let ((chunk (make-string 8192))
          (count 0)
          (output (make-string-output-stream)))
      (loop :for length := (read-sequence chunk stream)
            :until (zerop length)
            :do
               (incf count length)
               (when (> count *buffer-list-diff-input-limit*)
                 (editor-error "Ibuffer diff input exceeds ~d characters"
                               *buffer-list-diff-input-limit*))
               (write-sequence chunk output :end length))
      (get-output-stream-string output))))

(defun buffer-list-diff-buffer-text (buffer)
  (let ((text (points-to-string (buffer-start-point buffer)
                                (buffer-end-point buffer))))
    (when (> (length text) *buffer-list-diff-input-limit*)
      (editor-error "Ibuffer diff input exceeds ~d characters"
                    *buffer-list-diff-input-limit*))
    text))

(defun buffer-list-diff-section (buffer)
  (alexandria:when-let ((filename (buffer-filename buffer)))
    (let ((label (uiop:native-namestring filename)))
      (format nil "Buffer: ~a~%~a"
              (buffer-name buffer)
              (vundo-unified-diff
               (buffer-list-diff-file-text filename)
               (buffer-list-diff-buffer-text buffer)
               label
               (format nil "~a (buffer)" label))))))

(defun buffer-list-diff-sections (component)
  (let* ((ordinary-items
           (remove-if-not
            (lambda (item) (buffer-list-ordinary-marked-item-p component item))
            (buffer-list-component-all-items component)))
         (buffers
           (if ordinary-items
               (mapcar (lambda (item)
                         (buffer-list-entry-buffer (buffer-list-item-entry item)))
                       ordinary-items)
               (list (buffer-list-require-current-buffer component)))))
    (remove nil (mapcar #'buffer-list-diff-section buffers))))

(define-command lem-yath-buffer-list-diff-with-file () ()
  (let* ((component (lem/multi-column-list::current-multi-column-list))
         (sections (buffer-list-diff-sections component))
         (diff-buffer
           (make-buffer *buffer-list-diff-buffer-name* :enable-undo-p nil)))
    (buffer-disable-undo diff-buffer)
    (with-buffer-read-only diff-buffer nil
      (erase-buffer diff-buffer)
      (when sections
        (insert-string
         (buffer-start-point diff-buffer)
         (format nil "~{~a~^~%~}" sections)))
      (buffer-start (buffer-point diff-buffer)))
    (change-buffer-mode diff-buffer 'buffer-list-diff-mode)
    (buffer-mark-saved diff-buffer)
    (setf (buffer-read-only-p diff-buffer) t)
    (lem/multi-column-list:quit component)
    (switch-to-window (pop-to-buffer diff-buffer))))

(define-command lem-yath-buffer-list-revert () ()
  (let* ((component (lem/multi-column-list::current-multi-column-list))
         (focused-buffer (buffer-list-current-buffer component))
         (focused-index
           (or (position (buffer-list-current-item component)
                         (lem/multi-column-list::multi-column-list-items component)
                         :test #'eq)
               0))
         (buffers (buffer-list-action-buffers component)))
    (unless buffers
      (editor-error "No buffers to revert"))
    (if (not (buffer-list-confirm-revert buffers))
        (message "Revert cancelled")
        (let ((reverted 0)
              failed)
          (dolist (buffer buffers)
            (handler-case
                (progn
                  (buffer-list-revert-buffer buffer)
                  (incf reverted))
              (error () (push (buffer-name buffer) failed))))
          (buffer-list-refresh-after-buffer-mutation
           component focused-buffer focused-index)
          (if failed
              (message "Reverted ~d buffers; failed: ~{~a~^, ~}"
                       reverted (nreverse failed))
              (message "Operation finished; reverted ~d buffers" reverted))))))

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

(defun buffer-list-visible-group-names (component)
  (loop :for item :in (lem/multi-column-list::multi-column-list-items component)
        :for entry := (buffer-list-item-entry item)
        :when (buffer-list-entry-heading-p entry)
          :collect (buffer-list-entry-group entry)))

(defun buffer-list-focus-group (component name)
  (let* ((items (lem/multi-column-list::multi-column-list-items component))
         (index
           (position name items
                     :key (lambda (item)
                            (let ((entry (buffer-list-item-entry item)))
                              (and (buffer-list-entry-heading-p entry)
                                   (buffer-list-entry-group entry))))
                     :test #'string=)))
    (unless index
      (editor-error "No filter group with name ~a" name))
    (buffer-list-focus-index component index)))

(define-command lem-yath-buffer-list-jump-to-group () ()
  (let* ((component (lem/multi-column-list::current-multi-column-list))
         (names (buffer-list-visible-group-names component)))
    (unless names
      (editor-error "No Ibuffer filter groups are visible"))
    (let ((name
            (prompt-for-string
             "Jump to filter group: "
             :completion-function
             (lambda (input) (prescient-filter input names))
             :test-function
             (lambda (input) (member input names :test #'string=)))))
      (buffer-list-focus-group component name))))

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
(define-key *buffer-list-picker-mode-keymap* "Backspace"
  'lem-yath-buffer-list-unmark-backward)
(define-key *buffer-list-picker-mode-keymap* "C-h"
  'lem-yath-buffer-list-unmark-backward)
(define-key *buffer-list-picker-mode-keymap* 'delete-previous-char
  'lem-yath-buffer-list-unmark-backward)
(define-key *buffer-list-picker-mode-keymap* "Delete"
  'lem-yath-buffer-list-unmark-backward)
(define-key *buffer-list-picker-mode-keymap* "U"
  'lem-yath-buffer-list-unmark-all)
(define-key *buffer-list-picker-mode-keymap* "t"
  'lem-yath-buffer-list-toggle-marks)
(define-key *buffer-list-picker-mode-keymap* "~"
  'lem-yath-buffer-list-toggle-marks)
(define-key *buffer-list-picker-mode-keymap* "* *"
  'lem-yath-buffer-list-mark-special)
(define-key *buffer-list-picker-mode-keymap* "* s"
  'lem-yath-buffer-list-mark-special)
(define-key *buffer-list-picker-mode-keymap* "* m"
  'lem-yath-buffer-list-mark-modified)
(define-key *buffer-list-picker-mode-keymap* "* u"
  'lem-yath-buffer-list-mark-unsaved)
(define-key *buffer-list-picker-mode-keymap* "* r"
  'lem-yath-buffer-list-mark-read-only)
(define-key *buffer-list-picker-mode-keymap* "* /"
  'lem-yath-buffer-list-mark-dired)
(define-key *buffer-list-picker-mode-keymap* "* e"
  'lem-yath-buffer-list-mark-dissociated)
(define-key *buffer-list-picker-mode-keymap* "* h"
  'lem-yath-buffer-list-mark-help)
(define-key *buffer-list-picker-mode-keymap* "* z"
  'lem-yath-buffer-list-mark-compressed-file)
(define-key *buffer-list-picker-mode-keymap* "* M"
  'lem-yath-buffer-list-mark-by-mode)
(define-key *buffer-list-picker-mode-keymap* "."
  'lem-yath-buffer-list-mark-old)
(define-key *buffer-list-picker-mode-keymap* "% n"
  'lem-yath-buffer-list-mark-by-name-regexp)
(define-key *buffer-list-picker-mode-keymap* "% m"
  'lem-yath-buffer-list-mark-by-mode-regexp)
(define-key *buffer-list-picker-mode-keymap* "% f"
  'lem-yath-buffer-list-mark-by-file-regexp)
(define-key *buffer-list-picker-mode-keymap* "% g"
  'lem-yath-buffer-list-mark-by-content-regexp)
(define-key *buffer-list-picker-mode-keymap* "% L"
  'lem-yath-buffer-list-mark-locked)
(define-key *buffer-list-picker-mode-keymap* "d"
  'lem-yath-buffer-list-mark-deletion)
(define-key *buffer-list-picker-mode-keymap* "x"
  'lem-yath-buffer-list-execute-deletions)
(define-key *buffer-list-picker-mode-keymap* "S"
  'lem-yath-buffer-list-save-items)
(define-key *buffer-list-picker-mode-keymap* "="
  'lem-yath-buffer-list-diff-with-file)
(define-key *buffer-list-picker-mode-keymap* "J"
  'lem-yath-buffer-list-jump-to-buffer)
(define-key *buffer-list-picker-mode-keymap* "M-g"
  'lem-yath-buffer-list-jump-to-buffer)
(define-key *buffer-list-picker-mode-keymap* "M-j"
  'lem-yath-buffer-list-jump-to-group)
(define-key *buffer-list-picker-mode-keymap* "g j"
  'lem/multi-column-list::multi-column-list/down)
(define-key *buffer-list-picker-mode-keymap* "g k"
  'lem/multi-column-list::multi-column-list/up)
(define-key *buffer-list-picker-mode-keymap* "g r"
  'lem-yath-buffer-list-update)
(define-key *buffer-list-picker-mode-keymap* "g R"
  'lem-yath-buffer-list-redisplay)
(define-key *buffer-list-picker-mode-keymap* "-"
  'lem-yath-buffer-list-add-to-tmp-hide)
(define-key *buffer-list-picker-mode-keymap* "+"
  'lem-yath-buffer-list-add-to-tmp-show)
(define-key *buffer-list-picker-mode-keymap* "g o"
  'lem-yath-buffer-list-visit-other-window)
(define-key *buffer-list-picker-mode-keymap* "C-o"
  'lem-yath-buffer-list-visit-other-window-noselect)
(define-key *buffer-list-picker-mode-keymap* "M-o"
  'lem-yath-buffer-list-visit-one-window)
(define-key *buffer-list-picker-mode-keymap* "A"
  'lem-yath-buffer-list-view)
(define-key *buffer-list-picker-mode-keymap* "g v"
  'lem-yath-buffer-list-view)
(define-key *buffer-list-picker-mode-keymap* "g V"
  'lem-yath-buffer-list-view-horizontally)
(define-key *buffer-list-picker-mode-keymap* "O"
  'lem-yath-buffer-list-occur)
(define-key *buffer-list-picker-mode-keymap* "Q"
  'lem-yath-buffer-list-query-replace)
(define-key *buffer-list-picker-mode-keymap* "I"
  'lem-yath-buffer-list-query-replace-regexp)
(define-key *buffer-list-picker-mode-keymap* "M-s a C-o"
  'lem-yath-buffer-list-occur)
(define-key *buffer-list-picker-mode-keymap* "M-s a C-s"
  'lem-yath-buffer-list-multi-isearch)
(define-key *buffer-list-picker-mode-keymap* "M-s a M-C-s"
  'lem-yath-buffer-list-multi-isearch-regexp)
(define-key *buffer-list-picker-mode-keymap* "y b"
  'lem-yath-buffer-list-copy-buffer-name)
(define-key *buffer-list-picker-mode-keymap* "y f"
  'lem-yath-buffer-list-copy-file-name)
(define-key *buffer-list-picker-mode-keymap* "}"
  'lem-yath-buffer-list-next-marked)
(define-key *buffer-list-picker-mode-keymap* "M-}"
  'lem-yath-buffer-list-next-marked)
(define-key *buffer-list-picker-mode-keymap* "{"
  'lem-yath-buffer-list-previous-marked)
(define-key *buffer-list-picker-mode-keymap* "M-{"
  'lem-yath-buffer-list-previous-marked)
(define-key *buffer-list-picker-mode-keymap* "M"
  'lem-yath-buffer-list-toggle-modified)
(define-key *buffer-list-picker-mode-keymap* "T"
  'lem-yath-buffer-list-toggle-read-only)
(define-key *buffer-list-picker-mode-keymap* "L"
  'lem-yath-buffer-list-toggle-lock)
(define-key *buffer-list-picker-mode-keymap* "R"
  'lem-yath-buffer-list-rename-uniquely)
(define-key *buffer-list-picker-mode-keymap* "X"
  'lem-yath-buffer-list-bury)
(define-key *buffer-list-picker-mode-keymap* "K"
  'lem-yath-buffer-list-kill-lines)
(define-key *buffer-list-picker-mode-keymap* "V"
  'lem-yath-buffer-list-revert)
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
(define-key *buffer-list-picker-mode-keymap* "s Return"
  'lem-yath-buffer-list-filter-by-mode)
(define-key *buffer-list-picker-mode-keymap* "s n"
  'lem-yath-buffer-list-start-name-filter)
(define-key *buffer-list-picker-mode-keymap* "s m"
  'lem-yath-buffer-list-start-mode-filter)
(define-key *buffer-list-picker-mode-keymap* "s M"
  'lem-yath-buffer-list-filter-by-derived-mode)
(define-key *buffer-list-picker-mode-keymap* "s *"
  'lem-yath-buffer-list-filter-starred-name)
(define-key *buffer-list-picker-mode-keymap* "s E"
  'lem-yath-buffer-list-filter-process)
(define-key *buffer-list-picker-mode-keymap* "s f"
  'lem-yath-buffer-list-start-filename-filter)
(define-key *buffer-list-picker-mode-keymap* "s F"
  'lem-yath-buffer-list-start-directory-filter)
(define-key *buffer-list-picker-mode-keymap* "s b"
  'lem-yath-buffer-list-start-basename-filter)
(define-key *buffer-list-picker-mode-keymap* "s ."
  'lem-yath-buffer-list-start-extension-filter)
(define-key *buffer-list-picker-mode-keymap* "s <"
  'lem-yath-buffer-list-filter-size-lt)
(define-key *buffer-list-picker-mode-keymap* "s >"
  'lem-yath-buffer-list-filter-size-gt)
(define-key *buffer-list-picker-mode-keymap* "s i"
  'lem-yath-buffer-list-filter-modified)
(define-key *buffer-list-picker-mode-keymap* "s v"
  'lem-yath-buffer-list-filter-visiting-file)
(define-key *buffer-list-picker-mode-keymap* "s c"
  'lem-yath-buffer-list-filter-content)
(define-key *buffer-list-picker-mode-keymap* "s p"
  'lem-yath-buffer-list-pop-filter)
(define-key *buffer-list-picker-mode-keymap* "s t"
  'lem-yath-buffer-list-exchange-filters)
(define-key *buffer-list-picker-mode-keymap* "s Tab"
  'lem-yath-buffer-list-exchange-filters)
(define-key *buffer-list-picker-mode-keymap* "s o"
  'lem-yath-buffer-list-or-filter)
(define-key *buffer-list-picker-mode-keymap* "s |"
  'lem-yath-buffer-list-or-filter)
(define-key *buffer-list-picker-mode-keymap* "s &"
  'lem-yath-buffer-list-and-filter)
(define-key *buffer-list-picker-mode-keymap* "s d"
  'lem-yath-buffer-list-decompose-filter)
(define-key *buffer-list-picker-mode-keymap* "s g"
  'lem-yath-buffer-list-filters-to-filter-group)
(define-key *buffer-list-picker-mode-keymap* "s P"
  'lem-yath-buffer-list-pop-filter-group)
(define-key *buffer-list-picker-mode-keymap* "s Shift-Up"
  'lem-yath-buffer-list-pop-filter-group)
(define-key *buffer-list-picker-mode-keymap* "s D"
  'lem-yath-buffer-list-decompose-filter-group)
(define-key *buffer-list-picker-mode-keymap* "s S"
  'lem-yath-buffer-list-save-filter-groups)
(define-key *buffer-list-picker-mode-keymap* "s R"
  'lem-yath-buffer-list-switch-to-saved-filter-groups)
(define-key *buffer-list-picker-mode-keymap* "s X"
  'lem-yath-buffer-list-delete-saved-filter-groups)
(define-key *buffer-list-picker-mode-keymap* "s \\"
  'lem-yath-buffer-list-clear-filter-groups)
(define-key *buffer-list-picker-mode-keymap* "s s"
  'lem-yath-buffer-list-save-filters)
(define-key *buffer-list-picker-mode-keymap* "s a"
  'lem-yath-buffer-list-add-saved-filters)
(define-key *buffer-list-picker-mode-keymap* "s r"
  'lem-yath-buffer-list-switch-to-saved-filters)
(define-key *buffer-list-picker-mode-keymap* "s x"
  'lem-yath-buffer-list-delete-saved-filters)
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

(define-key *buffer-list-occur-mode-keymap* "Return"
  'lem-yath-buffer-list-occur-visit)
(define-key *buffer-list-occur-mode-keymap* "C-c C-c"
  'lem-yath-buffer-list-occur-visit)
(define-key *buffer-list-occur-mode-keymap* "S-Return"
  'lem-yath-buffer-list-occur-visit)
(define-key *buffer-list-occur-mode-keymap* "g o"
  'lem-yath-buffer-list-occur-visit)
(define-key *buffer-list-occur-mode-keymap* "M-Return"
  'lem-yath-buffer-list-occur-display)
(define-key *buffer-list-occur-mode-keymap* "g j"
  'lem-yath-buffer-list-occur-next)
(define-key *buffer-list-occur-mode-keymap* "g k"
  'lem-yath-buffer-list-occur-previous)
(define-key *buffer-list-occur-mode-keymap* "C-j"
  'lem-yath-buffer-list-occur-next)
(define-key *buffer-list-occur-mode-keymap* "C-k"
  'lem-yath-buffer-list-occur-previous)
(define-key *buffer-list-occur-mode-keymap* "n"
  'lem-yath-buffer-list-occur-next)
(define-key *buffer-list-occur-mode-keymap* "p"
  'lem-yath-buffer-list-occur-previous)
(define-key *buffer-list-occur-mode-keymap* "i"
  'lem-yath-buffer-list-occur-edit)
(define-key *buffer-list-occur-mode-keymap* "C-x C-q"
  'lem-yath-buffer-list-occur-edit)
(define-key *buffer-list-occur-mode-keymap* "r"
  'lem-yath-buffer-list-occur-rename)
(define-key *buffer-list-occur-mode-keymap* "c"
  'lem-yath-buffer-list-occur-clone)
(define-key *buffer-list-occur-mode-keymap* "q" 'quit-active-window)
(define-key *buffer-list-occur-mode-keymap* "Z Z" 'quit-active-window)
(define-key *buffer-list-occur-mode-keymap* "Z Q"
  'lem-vi-mode/commands:vi-quit)

(define-key *buffer-list-occur-edit-mode-keymap* "C-x C-q"
  'lem-yath-buffer-list-occur-cease-edit)
(define-key *buffer-list-occur-edit-mode-keymap* "C-c C-c"
  'lem-yath-buffer-list-occur-cease-edit)
(define-key *buffer-list-occur-edit-mode-keymap* "Escape"
  'lem-yath-buffer-list-occur-edit-escape)
(define-key *buffer-list-occur-edit-mode-keymap* "Z Z"
  'lem-yath-buffer-list-occur-cease-edit)
(define-key *buffer-list-occur-edit-mode-keymap* "Z Q"
  'lem-yath-buffer-list-occur-cease-edit)
(define-key *buffer-list-occur-edit-mode-keymap* "C-o"
  'lem-yath-buffer-list-occur-display)

(define-key *buffer-list-multi-isearch-mode-keymap* "C-s"
  'lem-yath-buffer-list-multi-isearch-next)
(define-key *buffer-list-multi-isearch-mode-keymap* "C-r"
  'lem-yath-buffer-list-multi-isearch-previous)
(define-key *buffer-list-multi-isearch-mode-keymap* "C-g"
  'lem-yath-buffer-list-multi-isearch-abort)

(remove-hook (variable-value 'kill-buffer-hook :global t)
             'buffer-list-occur-kill-buffer-hook)
(add-hook (variable-value 'kill-buffer-hook :global t)
          'buffer-list-occur-kill-buffer-hook)

(remove-hook *post-command-hook* 'buffer-list-multi-isearch-post-command)
(add-hook *post-command-hook* 'buffer-list-multi-isearch-post-command)
