;;;; Host-gated office-document presentation matching yath/business-visual.
;;;;
;;;; Lem's ncurses frontend has no proportional fonts, fractional line
;;;; spacing, fringes, or GUI chrome.  This module implements the useful
;;;; terminal analogue without changing the ordinary ex44 profile: a calm
;;;; light palette, compact modeline, shape-based cursors, and buffer-local
;;;; 88-column document pages.  The profile starts automatically only on the
;;;; same configured host as Emacs, but remains manually toggleable elsewhere.

(in-package :lem-yath)

(defparameter *business-visual-hosts* '("workwin")
  "Short host names where the business visual profile starts automatically.")

(defparameter *business-visual-theme* "business-operandi")
(defparameter *business-document-width* 88)

(defparameter *business-document-mode-classes*
  '(org-mode
    lem-markdown-mode:markdown-mode
    notmuch-show-mode
    lem-yath-feed-entry-mode
    devdocs-mode
    lem-yath-help-mode)
  "Lem major-mode classes corresponding to Emacs business document modes.")

(defparameter *business-document-text-types* '("txt" "text")
  "Fundamental-mode file types treated like Emacs text-mode documents.")

(defvar *business-visual-saved-theme* nil)
(defvar *business-visual-saved-modeline* nil)
(defvar *business-visual-saved-jump-feedback* nil)

(defvar *business-document-unbound* (gensym "BUSINESS-DOCUMENT-UNBOUND"))
(defvar *business-document-state-key* 'business-document-saved-state)

(lem-core:define-color-theme "business-operandi" ("emacs-light")
  (:display-background-mode :light)
  (:foreground "#1f2933")
  (:background "#fbfbfa")
  (:inactive-window-background "#f1f3f5")

  (:base00 "#fbfbfa")
  (:base01 "#f3f4f6")
  (:base02 "#e6e8eb")
  (:base03 "#667085")
  (:base04 "#475467")
  (:base05 "#1f2933")
  (:base06 "#17233c")
  (:base07 "#ffffff")
  (:base08 "#b42318")
  (:base09 "#b54708")
  (:base0A "#7a5d00")
  (:base0B "#18794e")
  (:base0C "#0e7490")
  (:base0D "#274060")
  (:base0E "#6941c6")
  (:base0F "#9f1239")

  (lem-core:region :foreground "#1f2933" :background "#cfe0f5")
  (lem-core:modeline :foreground "#1f2933" :background "#e6e8eb")
  (lem-core:modeline-inactive :foreground "#667085" :background "#f1f3f5")
  (lem-core:truncate-attribute :foreground "#7a5d00")
  (lem-core::special-char-attribute :foreground "#b42318")
  (lem-core:compiler-note-attribute :underline "#b42318")

  (lem-core:syntax-warning-attribute :foreground "#7a5d00" :bold t)
  (lem-core:syntax-string-attribute :foreground "#1d4ed8")
  (lem-core:syntax-comment-attribute :foreground "#6b7280")
  (lem-core:syntax-keyword-attribute :foreground "#274060" :bold t)
  (lem-core:syntax-constant-attribute :foreground "#6941c6")
  (lem-core:syntax-function-name-attribute :foreground "#7e22ce")
  (lem-core:syntax-variable-attribute :foreground "#0e7490")
  (lem-core:syntax-type-attribute :foreground "#18794e" :bold t)
  (lem-core:syntax-builtin-attribute :foreground "#9f1239" :bold t)

  (lem-core::modeline-name-attribute :foreground "#1f2933" :bold t)
  (lem-core::inactive-modeline-name-attribute :foreground "#667085" :bold t)
  (lem-core::modeline-major-mode-attribute :foreground "#274060")
  (lem-core::inactive-modeline-major-mode-attribute :foreground "#667085")
  (lem-core::modeline-minor-modes-attribute :foreground "#1f2933")
  (lem-core::inactive-modeline-minor-modes-attribute :foreground "#667085")
  (lem-core::modeline-position-attribute
   :foreground "#1f2933" :background "#e6e8eb")
  (lem-core::inactive-modeline-position-attribute
   :foreground "#667085" :background "#f1f3f5")
  (lem-core::modeline-posline-attribute
   :foreground "#1f2933" :background "#e6e8eb")
  (lem-core::inactive-modeline-posline-attribute
   :foreground "#667085" :background "#f1f3f5")

  (lem/line-numbers:line-numbers-attribute
   :foreground "#9aa4b2" :background "#f3f4f6")
  (lem/line-numbers:active-line-number-attribute
   :foreground "#3f4a59" :background "#e9edf2" :bold t)
  (lem/show-paren:showparen-attribute
   :foreground "#17233c" :background "#cfe0f5")
  (dap-breakpoint-attribute :foreground "#b42318" :bold t)
  (dap-breakpoint-pending-attribute :foreground "#b54708" :bold t)
  (dap-stopped-gutter-attribute :foreground "#18794e" :bold t)
  (dap-stopped-line-attribute :background "#e8f5ee")
  (dap-info-heading-attribute :foreground "#274060" :bold t)
  (dap-info-error-attribute :foreground "#b42318" :bold t)
  (lem-yath-jump-pulse-1-attribute :background "#f3f6f9")
  (lem-yath-jump-pulse-2-attribute :background "#edf2f7")
  (lem-yath-jump-pulse-3-attribute :background "#e6edf5")
  (lem-yath-jump-pulse-4-attribute :background "#dce7f2")
  (lem-yath-indent-guide-1-attribute :foreground "#c8ced6")
  (lem-yath-indent-guide-2-attribute :foreground "#b9c8ca")
  (lem-yath-indent-guide-3-attribute :foreground "#c8bdca")
  (lem-yath-indent-guide-4-attribute :foreground "#c4c7b9")
  (lem-yath-indent-guide-5-attribute :foreground "#bbc4cf")
  (lem-yath-indent-guide-6-attribute :foreground "#ccbdbf")
  (lem/isearch:isearch-highlight-attribute
   :foreground "#17233c" :background "#cfe0f5")
  (lem/isearch:isearch-highlight-active-attribute
   :foreground "#17233c" :background "#f5dda9")
  (lem/prompt-window:prompt-attribute :foreground "#0e7490" :bold t)
  (lem/link::link-attribute :foreground "#274060" :underline t)

  (lem-lisp-mode/paren-coloring:paren-color-1 :foreground "#1f2933")
  (lem-lisp-mode/paren-coloring:paren-color-2 :foreground "#7e22ce")
  (lem-lisp-mode/paren-coloring:paren-color-3 :foreground "#0e7490")
  (lem-lisp-mode/paren-coloring:paren-color-4 :foreground "#b42318")
  (lem-lisp-mode/paren-coloring:paren-color-5 :foreground "#7a5d00")
  (lem-lisp-mode/paren-coloring:paren-color-6 :foreground "#6941c6")
  (rainbow-delimiter-color-7 :foreground "#18794e")
  (rainbow-delimiter-color-8 :foreground "#274060")
  (rainbow-delimiter-color-9 :foreground "#9f1239")
  (rainbow-delimiter-mismatched-attribute
   :foreground "#17233c" :background "#f5dda9")
  (rainbow-delimiter-unmatched-attribute
   :foreground "#ffffff" :background "#b42318")

  (lem-core:document-header1-attribute :foreground "#17233c" :bold t)
  (lem-core:document-header2-attribute :foreground "#1d3b5f" :bold t)
  (lem-core:document-header3-attribute :foreground "#274060" :bold t)
  (lem-core:document-header4-attribute :foreground "#344054" :bold t)
  (lem-core:document-header5-attribute :foreground "#475467" :bold t)
  (lem-core:document-header6-attribute :foreground "#667085" :bold t)
  (lem-core:document-bold-attribute :bold t)
  (lem-core:document-italic-attribute :foreground "#475467")
  (lem-core:document-underline-attribute :underline t)
  (lem-core:document-link-attribute :foreground "#274060" :underline t)
  (lem-core:document-list-attribute :foreground "#b54708")
  (lem-core:document-code-block-attribute
   :foreground "#18794e" :background "#f7f8fa")
  (lem-core:document-inline-code-attribute :foreground "#18794e")
  (lem-core:document-blockquote-attribute :foreground "#667085")
  (lem-core:document-table-attribute :foreground "#344054")
  (lem-core:document-task-list-attribute :foreground "#18794e")
  (lem-core:document-metadata-attribute :foreground "#98a2b3"))

(defun business-short-hostname ()
  "Return this machine's unqualified host name."
  (let* ((name (string-downcase (machine-instance)))
         (dot (position #\. name)))
    (subseq name 0 dot)))

(defun business-visual-enabled-host-p ()
  (member (business-short-hostname) *business-visual-hosts*
          :test #'string-equal))

(defun business-document-file-p (buffer)
  (alexandria:when-let ((filename (buffer-filename buffer)))
    (member (string-downcase (or (pathname-type filename) ""))
            *business-document-text-types*
            :test #'string=)))

(defun business-document-buffer-p (&optional (buffer (current-buffer)))
  "Whether BUFFER corresponds to one of Emacs's business document modes."
  (let* ((major (buffer-major-mode buffer))
         (object (and major (ensure-mode-object major))))
    (or (some (lambda (class) (typep object class))
              *business-document-mode-classes*)
        (and (typep object 'lem/buffer/fundamental-mode:fundamental-mode)
             (business-document-file-p buffer)))))

(defun business-buffer-value-state (buffer key)
  (buffer-value buffer key *business-document-unbound*))

(defun business-restore-buffer-value (buffer key value)
  (if (eq value *business-document-unbound*)
      (buffer-unbound buffer key)
      (setf (buffer-value buffer key) value)))

(defun business-document-save-state (buffer)
  (setf (buffer-value buffer *business-document-state-key*)
        (list :line-wrap (variable-value 'line-wrap :default buffer)
              :fill-column
              (business-buffer-value-state buffer 'lem-yath-fill-column)
              :centered-width
              (business-buffer-value-state
               buffer *centered-view-buffer-width-key*)
              :centered-active
              (mode-active-p buffer 'centered-view-mode))))

(defun business-document-apply ()
  (let ((buffer (current-buffer)))
    (unless (buffer-value buffer *business-document-state-key*)
      (business-document-save-state buffer))
    (setf (variable-value 'line-wrap :buffer buffer) t
          (buffer-value buffer 'lem-yath-fill-column)
          *business-document-width*
          (buffer-value buffer *centered-view-buffer-width-key*)
          *business-document-width*)
    (unless (mode-active-p buffer 'centered-view-mode)
      (centered-view-mode t))
    (centered-view-mark-visible-windows buffer)))

(defun business-document-enable ()
  (business-document-apply))

(defun business-document-disable ()
  (let* ((buffer (current-buffer))
         (state (buffer-value buffer *business-document-state-key*)))
    (when state
      (unless (getf state :centered-active)
        (centered-view-mode nil))
      (business-restore-buffer-value
       buffer 'lem-yath-fill-column (getf state :fill-column))
      (business-restore-buffer-value
       buffer *centered-view-buffer-width-key* (getf state :centered-width))
      (setf (variable-value 'line-wrap :buffer buffer)
            (getf state :line-wrap))
      (buffer-unbound buffer *business-document-state-key*)
      (centered-view-mark-visible-windows buffer))))

(define-minor-mode business-document-mode
    (:name "Doc"
     :enable-hook 'business-document-enable
     :disable-hook 'business-document-disable
     :hide-from-modeline t)
  "Present the current buffer as a calm 88-column document page.")

(defun business-visual-compact-modeline ()
  (let ((vi-element lem-vi-mode/modeline::*modeline-element*))
    (append (and vi-element (list vi-element))
            '(" "
              modeline-write-info
              modeline-name
              (modeline-position nil :right)
              (modeline-major-mode nil :right)))))

(defun configure-business-cursor-states ()
  "Use Emacs's business cursor shapes when the profile is active."
  (when (mode-active-p (current-buffer) 'business-visual-mode)
    (configure-vi-cursor-state 'lem-vi-mode/states:normal nil :box)
    (configure-vi-cursor-state 'lem-vi-mode/states:insert nil :bar)
    (configure-vi-cursor-state 'lem-vi-mode/states:replace-state nil :underline)
    (dolist (state '(lem-vi-mode/visual::visual-char
                     lem-vi-mode/visual::visual-line
                     lem-vi-mode/visual::visual-screen-line
                     lem-vi-mode/visual::visual-block))
      (configure-vi-cursor-state state nil :box))
    (reinitialize-instance *lem-yath-emacs-state*
                           :cursor-color nil
                           :cursor-type :bar)))

(defun business-visual-reconcile-buffer (&optional (buffer (current-buffer)))
  "Enable or remove document presentation in BUFFER as appropriate."
  (let ((wanted (and (mode-active-p buffer 'business-visual-mode)
                     (business-document-buffer-p buffer)))
        (active (mode-active-p buffer 'business-document-mode)))
    (cond
      ((and wanted (not active))
       (with-current-buffer buffer (business-document-mode t)))
      ((and wanted active)
       ;; Major-mode changes clear editor-local variables but retain Lem minor
       ;; modes.  Reassert the presentation without replacing the saved state.
       (with-current-buffer buffer (business-document-apply)))
      ((and active (not wanted))
       (with-current-buffer buffer (business-document-mode nil))))))

(defun business-visual-switch-buffer (buffer)
  (business-visual-reconcile-buffer buffer))

(defun business-visual-post-command ()
  (business-visual-reconcile-buffer (current-buffer)))

(defun business-visual-refresh-buffers ()
  (dolist (buffer (buffer-list))
    (business-visual-reconcile-buffer buffer)))

(defun business-visual-install-hooks ()
  (remove-hook *switch-to-buffer-hook* 'business-visual-switch-buffer)
  (remove-hook *post-command-hook* 'business-visual-post-command)
  (add-hook *switch-to-buffer-hook* 'business-visual-switch-buffer -200)
  (add-hook *post-command-hook* 'business-visual-post-command -200))

(defun business-visual-remove-hooks ()
  (remove-hook *switch-to-buffer-hook* 'business-visual-switch-buffer)
  (remove-hook *post-command-hook* 'business-visual-post-command))

(defun business-visual-enable ()
  (setf *business-visual-saved-theme* (current-theme)
        *business-visual-saved-modeline*
        (copy-list (variable-value 'modeline-format :global))
        *business-visual-saved-jump-feedback* *jump-feedback-enabled*
        *jump-feedback-enabled* nil)
  (load-theme *business-visual-theme* nil)
  (setf (variable-value 'modeline-format :global)
        (business-visual-compact-modeline))
  (configure-business-cursor-states)
  (business-visual-install-hooks)
  (business-visual-refresh-buffers)
  (redraw-display :force t))

(defun business-visual-disable ()
  (business-visual-remove-hooks)
  (business-visual-refresh-buffers)
  (setf *jump-feedback-enabled* *business-visual-saved-jump-feedback*)
  (when *business-visual-saved-modeline*
    (setf (variable-value 'modeline-format :global)
          *business-visual-saved-modeline*))
  (load-theme (or *business-visual-saved-theme* *lem-yath-color-theme*) nil)
  (setf *business-visual-saved-theme* nil
        *business-visual-saved-modeline* nil
        *business-visual-saved-jump-feedback* nil)
  (redraw-display :force t))

(define-minor-mode business-visual-mode
    (:name "Business"
     :global t
     :enable-hook 'business-visual-enable
     :disable-hook 'business-visual-disable
     :hide-from-modeline t)
  "Toggle the terminal office-document visual profile globally.")

(defun enable-business-visual-on-configured-host ()
  (when (business-visual-enabled-host-p)
    (business-visual-mode t)))

(remove-hook *after-load-theme-hook* 'configure-business-cursor-states)
(add-hook *after-load-theme-hook* 'configure-business-cursor-states -200)
(remove-hook *after-init-hook* 'enable-business-visual-on-configured-host)
(add-hook *after-init-hook* 'enable-business-visual-on-configured-host -200)

;; A live config reload retains the active global mode object.  Refresh its
;; hooks and buffers instead of toggling it or overwriting the saved baseline.
(when (and lem-core::*in-the-editor*
           (mode-active-p (current-buffer) 'business-visual-mode))
  (business-visual-install-hooks)
  (business-visual-refresh-buffers)
  (configure-business-cursor-states))
