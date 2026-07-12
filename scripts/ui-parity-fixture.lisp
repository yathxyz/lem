(in-package :lem-yath)

(defvar *ui-parity-report* (uiop:getenv "LEM_YATH_UI_PARITY_REPORT"))

(defun ui-parity-log (control &rest arguments)
  (with-open-file (stream *ui-parity-report*
                          :direction :output
                          :if-exists :append
                          :if-does-not-exist :create)
    (apply #'format stream control arguments)
    (terpri stream)))

(define-minor-mode lem-yath-test-left-gutter-mode
    (:name "UI parity fixture gutter"))

(defmethod compute-left-display-area-content
    ((mode lem-yath-test-left-gutter-mode) buffer point)
  (declare (ignore mode buffer point))
  (lem/buffer/line:make-content :string "fixture-gutter"))

(define-minor-mode lem-yath-test-global-gutter-mode
    (:name "UI parity fixture global gutter"
     :global t))

(defmethod compute-left-display-area-content
    ((mode lem-yath-test-global-gutter-mode) buffer point)
  (declare (ignore mode buffer point))
  (lem/buffer/line:make-content :string "G"))

(lem-yath-test-global-gutter-mode t)

(defvar *ui-parity-unrelated-keymap*
  (lem-core::make-keymap :description "Fixture unrelated"))

(define-command lem-yath-test-ui-unrelated-leaf () ()
  (ui-parity-log "UNRELATED leaf"))

(define-key *ui-parity-unrelated-keymap* "x"
  'lem-yath-test-ui-unrelated-leaf)
(setf (lem-core::prefix-description
       (lem-core::keymap-find
        *ui-parity-unrelated-keymap*
        (lem-core::parse-keyspec "x")))
      "fixture leaf"
      (lem/transient::keymap-show-p *ui-parity-unrelated-keymap*)
      t)
(define-key lem-vi-mode:*normal-keymap* "F12"
  *ui-parity-unrelated-keymap*)

(defun ui-parity-content-string (content)
  (and content (lem/buffer/line:content-string content)))

(defun ui-parity-probe-point (buffer)
  (let ((point (copy-point (buffer-start-point buffer))))
    (line-offset point 2)
    point))

(defun ui-parity-line-number-content (buffer point)
  (compute-left-display-area-content
   (ensure-mode-object 'lem/line-numbers::line-numbers-mode)
   buffer
   point))

(defun ui-parity-composed-left-content (buffer point)
  (compute-left-display-area-content
   (lem-core::get-active-modes-class-instance buffer)
   buffer
   point))

(defun ui-parity-attribute-colors (name)
  (let ((attribute (ensure-attribute name)))
    (format nil "~a/~a"
            (or (attribute-foreground attribute) "none")
            (or (attribute-background attribute) "none"))))

(defun ui-parity-hook-count (hook function)
  (count function hook :key #'car))

(defun ui-parity-key-command (keymap keys)
  (alexandria:when-let
      ((prefix (lem-core::keymap-find keymap
                                      (lem-core::parse-keyspec keys))))
    (lem-core::prefix-suffix prefix)))

(defun ui-parity-record-theme ()
  (ui-parity-log
   "THEME name=~a foreground=~a background=~a region=~a modeline=~a inactive=~a warning=~a string=~a comment=~a keyword=~a constant=~a function=~a variable=~a type=~a builtin=~a line=~a active-line=~a paren=~a"
   (current-theme)
   (foreground-color)
   (background-color)
   (ui-parity-attribute-colors 'region)
   (ui-parity-attribute-colors 'modeline)
   (ui-parity-attribute-colors 'modeline-inactive)
   (ui-parity-attribute-colors 'syntax-warning-attribute)
   (ui-parity-attribute-colors 'syntax-string-attribute)
   (ui-parity-attribute-colors 'syntax-comment-attribute)
   (ui-parity-attribute-colors 'syntax-keyword-attribute)
   (ui-parity-attribute-colors 'syntax-constant-attribute)
   (ui-parity-attribute-colors 'syntax-function-name-attribute)
   (ui-parity-attribute-colors 'syntax-variable-attribute)
   (ui-parity-attribute-colors 'syntax-type-attribute)
   (ui-parity-attribute-colors 'syntax-builtin-attribute)
   (ui-parity-attribute-colors 'lem/line-numbers:line-numbers-attribute)
   (ui-parity-attribute-colors 'lem/line-numbers:active-line-number-attribute)
   (ui-parity-attribute-colors 'lem/show-paren:showparen-attribute)))

(defun ui-parity-open-paren-attributes (buffer)
  (with-point ((point (buffer-start-point buffer))
               (end (buffer-end-point buffer)))
    (loop :while (and (point< point end)
                      (not (end-line-p point)))
          :for character := (character-at point)
          :when (eql character #\()
            :collect (text-property-at point :attribute)
          :do (character-offset point 1))))

(define-command lem-yath-test-ui-theme-state () ()
  (alexandria:when-let ((path (uiop:getenv "LEM_YATH_UI_CODE_FILE")))
    (switch-to-buffer (find-file-buffer path)))
  (ui-parity-record-theme)
  (let ((attributes (ui-parity-open-paren-attributes (current-buffer))))
    (ui-parity-log "RAINBOW attributes=~{~a~^,~} colors=~{~a~^,~}"
                   attributes
                   (mapcar #'ui-parity-attribute-colors attributes)))
  (buffer-start (current-point))
  (lem/show-paren::update-show-paren)
  (ui-parity-log
   "SHOW-PAREN enabled=~a timer=~a overlays=~d colors=~{~a~^,~}"
   (if (variable-value 'lem/show-paren:enable) "yes" "no")
   (if lem/show-paren::*show-paren-timer* "yes" "no")
   (length lem/show-paren::*brackets-overlays*)
   (mapcar (lambda (overlay)
             (ui-parity-attribute-colors (overlay-attribute overlay)))
           lem/show-paren::*brackets-overlays*)))

(defun ui-parity-wrap-buffer ()
  (alexandria:when-let ((path (uiop:getenv "LEM_YATH_UI_WRAP_FILE")))
    (let ((buffer (find-file-buffer path)))
      (switch-to-buffer buffer)
      buffer)))

(defun ui-parity-record-wrap (label)
  (let* ((point (current-point))
         (window (current-window)))
    (ui-parity-log
     "WRAP label=~a enabled=~a line=~d column=~d body-width=~d cursor-y=~d"
     label
     (if (variable-value 'line-wrap :default (current-buffer)) "yes" "no")
     (line-number-at-point point)
     (point-charpos point)
     (lem-core::window-body-width window)
     (lem-core::window-cursor-y window))))

(define-command lem-yath-test-ui-wrap-state () ()
  (when (ui-parity-wrap-buffer)
    (buffer-start (current-point))
    (redraw-display)
    (ui-parity-record-wrap "state")))

(defun ui-parity-record (label)
  (let ((buffer (current-buffer)))
    (buffer-start (buffer-point buffer))
    (let* ((point (ui-parity-probe-point buffer))
           (line-number
             (ui-parity-content-string
              (ui-parity-line-number-content buffer point)))
           (composed
             (ui-parity-content-string
              (ui-parity-composed-left-content buffer point))))
      (unwind-protect
           (ui-parity-log
            "STATE label=~a file=~a programming=~a line-mode=~a fixture-mode=~a git-mode=~a line-numbers=~a relative=~a number-width=~d gutter=~a gutter-width=~d popup=~a shown=~a"
            label
            (or (and (buffer-filename buffer)
                     (file-namestring (buffer-filename buffer)))
                "none")
            (if (programming-buffer-p buffer) "yes" "no")
            (if (lem-core::mode-active-p
                 buffer 'lem/line-numbers::line-numbers-mode)
                "yes"
                "no")
            (if (lem-core::mode-active-p
                 buffer 'lem-yath-test-global-gutter-mode)
                "yes"
                "no")
            (if (lem-core::mode-active-p
                 buffer 'lem-yath-git-gutter-mode)
                "yes"
                "no")
            (if line-number "yes" "no")
            (or (and line-number
                     (string-trim '(#\Space #\Tab) line-number))
                "none")
            (length (or line-number ""))
            (or (and composed
                     (string-trim '(#\Space #\Tab) composed))
                "none")
            (length (or composed ""))
            (if (lem/transient::transient-window-alive-p) "yes" "no")
            (or (and lem/transient::*transient-shown-keymap*
                     (lem-core::keymap-description
                      lem/transient::*transient-shown-keymap*))
                "none"))
        (delete-point point)))))

(define-command lem-yath-test-ui-static-checks () ()
  (let ((failures 0))
    (flet ((check (condition name)
             (ui-parity-log "~a STATIC ~a"
                            (if condition "PASS" "FAIL")
                            name)
             (unless condition
               (incf failures))))
      (check (evil-leader-bindings-ok-p)
             "leader-bindings-preserved")
      (check (evil-leader-help-ok-p)
             "shared-described-transient-tree")
      (check (= 1000 *leader-help-delay*)
             "one-second-configured-delay")
      (check (= 500 lem/transient:*transient-popup-delay*)
             "upstream-transient-delay-preserved")
      (check (not (leader-help-keymap-p *ui-parity-unrelated-keymap*))
             "unrelated-keymap-not-marked-as-leader")
      (check (not lem/transient:*transient-always-show*)
             "unrelated-keymaps-not-perpetual")
      (check (lem-core::mode-active-p
              (current-buffer) 'lem-yath-git-gutter-mode)
             "programming-buffer-git-gutter-started")
      (check (not (member 'lem-git-gutter::git-gutter-mode
                          (lem-core::active-global-minor-modes)))
             "upstream-global-git-gutter-disabled")
      (check (not (variable-value
                   'lem/frame-multiplexer::frame-multiplexer :global))
             "frame-multiplexer-not-started")
      (check (zerop (ui-parity-hook-count
                     *after-init-hook*
                     'lem/frame-multiplexer::enable-frame-multiplexer))
             "frame-multiplexer-autostart-removed")
      (check (let ((keymap lem/frame-multiplexer:*keymap*))
               (and (eq 'lem-yath-frame-create
                        (ui-parity-key-command keymap "2"))
                    (eq 'lem-yath-frame-create
                        (ui-parity-key-command keymap "c"))
                    (eq 'lem-yath-frame-create-with-previous-buffer
                        (ui-parity-key-command keymap "C"))))
             "frame-multiplexer-on-demand-bindings")
      (check (not (variable-value 'line-wrap :global))
             "long-lines-truncated-by-default")
      (check (not (variable-value 'highlight-line :global))
             "current-line-highlight-disabled")
      (check (variable-value
              'lem-lisp-mode/paren-coloring:paren-coloring :global)
             "rainbow-delimiters-enabled")
      (check (= 1 (ui-parity-hook-count
                   (variable-value 'after-syntax-scan-hook :global)
                   'lem-lisp-mode/paren-coloring:paren-coloring))
             "one-rainbow-delimiter-hook")
      (check (and (string= "modus-vivendi-tinted" (current-theme))
                  (string= "#ffffff" (foreground-color))
                  (string= "#0d0e1c" (background-color)))
             "current-emacs-theme-loaded")
      (check (and (eq 'lem-yath-llm-set-backend
                      (leader-binding-command
                       lem-vi-mode:*normal-keymap* "g b"))
                  (eq 'lem-yath-llm-set-backend
                      (leader-binding-command
                       lem-vi-mode:*visual-keymap* "g b")))
             "LLM-backend-binding-preserved")
      (check (string= "Leader p: project"
                      (lem-core::keymap-description
                       (lem-core::prefix-suffix
                        (leader-prefix *evil-leader-keymap* "p"))))
             "project-prefix-description")
      (ui-parity-log "SUMMARY STATIC ~a failures=~d"
                     (if (zerop failures) "PASS" "FAIL")
                     failures))))

(define-command lem-yath-test-ui-reload-display () ()
  (let ((root (asdf:system-source-directory "lem-yath")))
    (load (merge-pathnames "src/theme.lisp" root))
    (load (merge-pathnames "src/ui.lisp" root)))
  (ui-parity-log
   "DISPLAY-RELOAD theme=~a wrap=~a highlight=~a frame=~a rainbow-hooks=~d"
   (current-theme)
   (if (variable-value 'line-wrap :global) "yes" "no")
   (if (variable-value 'highlight-line :global) "yes" "no")
   (if (variable-value 'lem/frame-multiplexer::frame-multiplexer :global)
       "yes" "no")
   (ui-parity-hook-count
    (variable-value 'after-syntax-scan-hook :global)
    'lem-lisp-mode/paren-coloring:paren-coloring)))

(define-command lem-yath-test-ui-frame-state () ()
  (ui-parity-log
   "FRAME enabled=~a count=~d"
   (if (variable-value 'lem/frame-multiplexer::frame-multiplexer :global)
       "yes"
       "no")
   (loop :for virtual-frame :being :the :hash-values
           :of lem/frame-multiplexer::*virtual-frame-map*
         :sum (lem/frame-multiplexer::num-frames virtual-frame))))

(define-command lem-yath-test-ui-reload-active-tabs () ()
  (load (merge-pathnames "src/ui.lisp"
                         (asdf:system-source-directory "lem-yath")))
  (ui-parity-log
   "TAB-RELOAD enabled=~a count=~d"
   (if (variable-value 'lem/frame-multiplexer::frame-multiplexer :global)
       "yes"
       "no")
   (loop :for virtual-frame :being :the :hash-values
           :of lem/frame-multiplexer::*virtual-frame-map*
         :sum (lem/frame-multiplexer::num-frames virtual-frame))))

(define-command lem-yath-test-ui-code-state () ()
  (alexandria:when-let ((path (uiop:getenv "LEM_YATH_UI_CODE_FILE")))
    (switch-to-buffer (find-file-buffer path)))
  (ui-parity-record "code"))

(define-command lem-yath-test-ui-reordered-code-state () ()
  ;; Re-enabling pushes line-numbers to the end of the active global mode list.
  ;; Its global column must still compose with the buffer-local Git column.
  (lem/line-numbers:toggle-line-numbers)
  (lem/line-numbers:toggle-line-numbers)
  (ui-parity-record "code-reordered"))

(define-command lem-yath-test-ui-production-gutters () ()
  (lem-yath-test-global-gutter-mode nil)
  (unwind-protect
       (ui-parity-record "production-gutters")
    (lem-yath-test-global-gutter-mode t)))

(define-command lem-yath-test-ui-prose-state () ()
  (alexandria:when-let ((path (uiop:getenv "LEM_YATH_UI_PROSE_FILE")))
    (switch-to-buffer (find-file-buffer path)))
  (lem-yath-test-left-gutter-mode t)
  (ui-parity-record "prose"))

(define-command lem-yath-test-ui-unsaved-code-state () ()
  (let ((buffer (or (get-buffer "*ui-parity-unsaved-code*")
                    (make-buffer "*ui-parity-unsaved-code*"))))
    (change-buffer-mode buffer 'lem-lisp-mode:lisp-mode)
    (with-buffer-read-only buffer nil
      (erase-buffer buffer)
      (insert-string (buffer-point buffer)
                     (format nil
                             "(defun unsaved-one ())~%(defun unsaved-two ())~%(defun unsaved-three ())~%")))
    (buffer-unmark buffer)
    (lem-yath-git-gutter-sync-buffer buffer)
    (switch-to-buffer buffer))
  (ui-parity-record "unsaved-code"))

(defvar *ui-parity-fast-command-count* 0)

(define-command lem-yath-test-ui-fast-command () ()
  (incf *ui-parity-fast-command-count*)
  (ui-parity-log "FAST count=~d popup=~a"
                 *ui-parity-fast-command-count*
                 (if (lem/transient::transient-window-alive-p)
                     "yes"
                     "no")))

(defun ui-parity-install-fast-command ()
  (define-key *evil-leader-keymap* "z" 'lem-yath-test-ui-fast-command)
  (setf (lem-core::prefix-description
         (leader-prefix *evil-leader-keymap* "z"))
        "fixture fast command"))

(defun ui-parity-direct-leader-prefix-count (keymap)
  (length
   (lem-core::find-prefix-matches
    keymap
    (first (lem-core::parse-keyspec "Leader"))
    :active-only t)))

(define-command lem-yath-test-ui-rebuild-leader () ()
  (let* ((old-keymap *evil-leader-keymap*)
         (_ (keymap-activate old-keymap))
         (old-timer lem/transient::*transient-delay-timer*)
         (timer-before (not (null old-timer))))
    (declare (ignore _))
    (rebuild-evil-leader-keymap)
    (let ((timer-after (not (null lem/transient::*transient-delay-timer*))))
      ;; Model a callback that was queued just before cancellation.  The pinned
      ;; transient fix must reject it by timer identity.
      (when old-timer
        (funcall (lem/common/timer::timer-function old-timer)))
      (let ((stale-callback-safe
              (and (null lem/transient::*transient-delay-timer*)
                   (not (lem/transient::transient-window-alive-p)))))
      (lem/transient::show-transient *evil-leader-keymap*)
      (let ((window-before (lem/transient::transient-window-alive-p))
            (shown-keymap *evil-leader-keymap*))
        (rebuild-evil-leader-keymap)
        ;; Warm both parent caches before adding a fixture-only child binding;
        ;; the shared map's parent links must invalidate both caches.
        (lem-core::collect-command-keybindings
         'lem-yath-test-ui-fast-command lem-vi-mode:*normal-keymap*)
        (lem-core::collect-command-keybindings
         'lem-yath-test-ui-fast-command lem-vi-mode:*visual-keymap*)
        (ui-parity-install-fast-command)
        (ui-parity-log
         "REBUILD changed=~a timer-before=~a timer-after=~a stale-callback-safe=~a window-before=~a window-after=~a shown-replaced=~a normal-prefixes=~d visual-prefixes=~d cache-normal=~a cache-visual=~a bindings=~a help=~a"
         (if (not (eq old-keymap *evil-leader-keymap*)) "yes" "no")
         (if timer-before "yes" "no")
         (if timer-after "yes" "no")
         (if stale-callback-safe "yes" "no")
         (if window-before "yes" "no")
         (if (lem/transient::transient-window-alive-p) "yes" "no")
         (if (not (eq shown-keymap *evil-leader-keymap*)) "yes" "no")
         (ui-parity-direct-leader-prefix-count
          lem-vi-mode:*normal-keymap*)
         (ui-parity-direct-leader-prefix-count
          lem-vi-mode:*visual-keymap*)
         (if (lem-core::collect-command-keybindings
              'lem-yath-test-ui-fast-command
              lem-vi-mode:*normal-keymap*)
             "yes"
             "no")
         (if (lem-core::collect-command-keybindings
              'lem-yath-test-ui-fast-command
              lem-vi-mode:*visual-keymap*)
             "yes"
             "no")
         (if (evil-leader-bindings-ok-p) "yes" "no")
         (if (evil-leader-help-ok-p) "yes" "no")))))))

(ui-parity-install-fast-command)

(ui-parity-log "READY")
