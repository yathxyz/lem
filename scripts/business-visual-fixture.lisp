(in-package :lem-yath)

(defvar *business-visual-test-report*
  (uiop:getenv "LEM_YATH_BUSINESS_VISUAL_REPORT"))

(defvar *business-visual-test-baseline-modeline* nil)

(defun business-visual-test-log (control &rest arguments)
  (with-open-file (stream *business-visual-test-report*
                          :direction :output
                          :if-exists :append
                          :if-does-not-exist :create)
    (apply #'format stream control arguments)
    (terpri stream)))

(defun business-visual-test-yes-no (value)
  (if value "yes" "no"))

(defun business-visual-test-modeline-has-p (name)
  (find name
        (variable-value 'modeline-format :global)
        :key (lambda (item) (if (consp item) (first item) item))))

(defun business-visual-test-cursor-type (state)
  (string-downcase
   (symbol-name
    (lem-vi-mode/core::state-cursor-type
     (lem-vi-mode/core:ensure-state state)))))

(defun business-visual-test-record (label)
  (redraw-display :force t)
  (let* ((buffer (current-buffer))
         (window (current-window))
         (format (variable-value 'modeline-format :global)))
    (business-visual-test-log
     (concatenate
      'string
      "STATE label=~a host=~a theme=~a global=~a doc=~a center=~a "
      "wrap=~a target=~d fill=~d jump=~a compact=~a vi=~a "
      "normal=~a insert=~a emacs=~a replace=~a fg=~a bg=~a "
      "region=~a geometry=~d:~d:~d:~d")
     label
     (business-short-hostname)
     (current-theme)
     (business-visual-test-yes-no
      (mode-active-p buffer 'business-visual-mode))
     (business-visual-test-yes-no
      (mode-active-p buffer 'business-document-mode))
     (business-visual-test-yes-no
      (mode-active-p buffer 'centered-view-mode))
     (business-visual-test-yes-no
      (variable-value 'line-wrap :default buffer))
     (centered-view-width-for-buffer buffer)
     (lem-yath-buffer-fill-column buffer)
     (business-visual-test-yes-no *jump-feedback-enabled*)
     (business-visual-test-yes-no
      (and (not (business-visual-test-modeline-has-p
                 'modeline-minor-modes))
           (not (business-visual-test-modeline-has-p 'modeline-posline))))
     (business-visual-test-yes-no
      (and lem-vi-mode/modeline::*modeline-element*
           (find lem-vi-mode/modeline::*modeline-element* format)))
     (business-visual-test-cursor-type 'lem-vi-mode/states:normal)
     (business-visual-test-cursor-type 'lem-vi-mode/states:insert)
     (business-visual-test-cursor-type *lem-yath-emacs-state*)
     (business-visual-test-cursor-type 'lem-vi-mode/states:replace-state)
     (foreground-color)
     (background-color)
     (or (attribute-background (ensure-attribute 'region)) "none")
     (window-width window)
     (window-left-width window)
     (window-right-width window)
     (lem-core::window-body-width window))))

(defun business-visual-test-predicate (mode &optional filename)
  (let ((buffer (make-buffer nil :temporary t :enable-undo-p nil)))
    (unwind-protect
         (progn
           (when filename
             (setf (buffer-filename buffer) filename))
           (when mode
             (change-buffer-mode buffer mode))
           (business-document-buffer-p buffer))
      (ignore-errors (delete-buffer buffer)))))

(defun business-visual-test-record-predicates ()
  (business-visual-test-log
   (concatenate
    'string
    "PREDICATES org=~a markdown=~a epub=~a notmuch=~a feed=~a "
    "devdocs=~a text=~a pdf=~a search=~a lisp=~a")
   (business-visual-test-yes-no
    (business-visual-test-predicate 'org-mode))
   (business-visual-test-yes-no
    (business-visual-test-predicate 'lem-markdown-mode:markdown-mode))
   (business-visual-test-yes-no
    (business-visual-test-predicate 'document-epub-mode))
   (business-visual-test-yes-no
    (business-visual-test-predicate 'notmuch-show-mode))
   (business-visual-test-yes-no
    (business-visual-test-predicate 'lem-yath-feed-entry-mode))
   (business-visual-test-yes-no
    (business-visual-test-predicate 'devdocs-mode))
   (business-visual-test-yes-no
    (business-visual-test-predicate
     nil #P"/tmp/business-document.txt"))
   (business-visual-test-yes-no
    (business-visual-test-predicate 'document-pdf-mode))
   (business-visual-test-yes-no
    (business-visual-test-predicate 'notmuch-search-mode))
   (business-visual-test-yes-no
    (business-visual-test-predicate 'lem-lisp-mode:lisp-mode))))

(defun business-visual-test-preexisting-center ()
  (let ((buffer (make-buffer nil :temporary t :enable-undo-p nil)))
    (unwind-protect
         (with-current-buffer buffer
           (change-buffer-mode buffer 'lem-markdown-mode:markdown-mode)
           (setf (buffer-value buffer *centered-view-buffer-width-key*) 77)
           (centered-view-mode t)
           (business-visual-reconcile-buffer buffer)
           (let ((during
                   (and (mode-active-p buffer 'business-document-mode)
                        (= 88 (centered-view-width-for-buffer buffer)))))
             (business-document-mode nil)
             (business-visual-test-log
              "PREEXIST during=~a center=~a target=~d wrap=~a"
              (business-visual-test-yes-no during)
              (business-visual-test-yes-no
               (mode-active-p buffer 'centered-view-mode))
              (centered-view-width-for-buffer buffer)
              (business-visual-test-yes-no
               (variable-value 'line-wrap :default buffer)))))
      (ignore-errors (delete-buffer buffer)))))

(define-command lem-yath-test-business-enable () ()
  (business-visual-mode t)
  (business-visual-test-record "enabled")
  (business-visual-test-record-predicates)
  (business-visual-test-preexisting-center))

(define-command lem-yath-test-business-reload () ()
  (load (merge-pathnames "src/business-visual.lisp"
                         (asdf:system-source-directory "lem-yath")))
  (business-visual-test-record "reload"))

(define-command lem-yath-test-business-transition () ()
  (let ((buffer (current-buffer)))
    (change-buffer-mode buffer 'lem-lisp-mode:lisp-mode)
    (business-visual-reconcile-buffer buffer)
    (business-visual-test-record "code")
    (change-buffer-mode buffer 'org-mode)
    (business-visual-reconcile-buffer buffer)
    (business-visual-test-record "org-return")))

(define-command lem-yath-test-business-disable () ()
  (business-visual-mode nil)
  (business-visual-test-log
   "RESTORE modeline=~a default-hosts=~a"
   (business-visual-test-yes-no
    (equal *business-visual-test-baseline-modeline*
           (variable-value 'modeline-format :global)))
   (business-visual-test-yes-no
    (equal '("workwin") *business-visual-hosts*)))
  (business-visual-test-record "disabled"))

(define-key lem-vi-mode:*normal-keymap* "F5"
  'lem-yath-test-business-enable)
(define-key lem-vi-mode:*normal-keymap* "F6"
  'lem-yath-test-business-reload)
(define-key lem-vi-mode:*normal-keymap* "F7"
  'lem-yath-test-business-transition)
(define-key lem-vi-mode:*normal-keymap* "F8"
  'lem-yath-test-business-disable)

(let ((matched (business-visual-enabled-host-p))
      (active (mode-active-p (current-buffer) 'business-visual-mode)))
  (business-visual-test-log
   "HOST default=~a actual=~a matched=~a auto=~a consistent=~a"
   (business-visual-test-yes-no
    (equal '("workwin") *business-visual-hosts*))
   (business-short-hostname)
   (business-visual-test-yes-no matched)
   (business-visual-test-yes-no active)
   (business-visual-test-yes-no (eq (not (null matched)) active)))
  ;; Normalize the behavioral baseline even when this gate runs on workwin.
  (when active
    (business-visual-mode nil)))

(setf *business-visual-test-baseline-modeline*
      (copy-list (variable-value 'modeline-format :global))
      (buffer-value (current-buffer) 'lem-yath-fill-column) 73
      (variable-value 'line-wrap :buffer (current-buffer)) nil)
(buffer-unbound (current-buffer) *centered-view-buffer-width-key*)
(when (mode-active-p (current-buffer) 'centered-view-mode)
  (centered-view-mode nil))
(business-visual-test-record "baseline")
(business-visual-test-log "READY")
