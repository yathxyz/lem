;;;; Evil cursor/state parity for Lem's Vi mode.
;;;;
;;;; The ordinary Emacs profile uses red NORMAL, green INSERT, and cyan EMACS
;;;; cursors.  Its optional workwin-only graphical profile adds cursor shapes;
;;;; Lem's portable terminal subset is box/bar/underline.  Keep one custom
;;;; buffer-local EMACS state inside Vi mode rather than changing Lem's
;;;; editor-wide global mode.

(in-package :lem-yath)

(defvar *lem-yath-emacs-state-keymap*
  (lem-vi-mode/core::make-vi-keymap
   :description '*lem-yath-emacs-state-keymap*))

(defclass lem-yath-emacs-state (lem-vi-mode/core:vi-state) ())

(defvar *lem-yath-emacs-state* nil)

(unless (typep *lem-yath-emacs-state* 'lem-yath-emacs-state)
  (setf *lem-yath-emacs-state*
        (make-instance 'lem-yath-emacs-state)))

(defun configure-vi-cursor-state (state color type)
  (reinitialize-instance (lem-vi-mode/core:ensure-state state)
                         :cursor-color color
                         :cursor-type type))

(defun configure-lem-yath-cursor-states ()
  "Apply the terminal cursor profile without replacing Vi state instances."
  (configure-vi-cursor-state 'lem-vi-mode/states:normal "red" :box)
  (configure-vi-cursor-state 'lem-vi-mode/states:insert "green" :bar)
  (configure-vi-cursor-state 'lem-vi-mode/states:replace-state nil :underline)
  (dolist (state '(lem-vi-mode/visual::visual-char
                   lem-vi-mode/visual::visual-line
                   lem-vi-mode/visual::visual-block))
    (configure-vi-cursor-state state nil :box))
  (reinitialize-instance
   *lem-yath-emacs-state*
   :name "EMACS"
   :cursor-color "cyan"
   :cursor-type :box
   :modeline-color 'lem-vi-mode/modeline:state-modeline-aqua
   :keymaps (list *lem-yath-emacs-state-keymap*))
  ;; ENSURE-STATE accepts objects directly, but registration also makes the
  ;; state inspectable and keeps symbolic buffer-state restoration possible.
  (setf (get 'lem-yath-emacs-state 'lem-vi-mode/core::state)
        *lem-yath-emacs-state*)
  (alexandria:when-let ((state (lem-vi-mode/core:current-state)))
    (setf (lem-vi-mode/core:current-state) state)))

(defmethod lem-vi-mode/core:state-changed-hook :after
    ((state lem-vi-mode/core:vi-state))
  ;; Ncurses caches the rendered cursor cell.  A state change updates the
  ;; shared cursor attribute, but a stationary cursor otherwise keeps the old
  ;; cell color until some unrelated edit invalidates the window.  Mark only
  ;; the focused window dirty; the ordinary post-command redraw then paints
  ;; the new state color after UPDATE-CURSOR-STYLES has run.
  (declare (ignore state))
  (alexandria:when-let* ((frame (current-frame))
                         (window (frame-current-window frame)))
    (lem-core::need-to-redraw window)))

(defun lem-yath-sync-vi-state-before-buffer-switch (buffer)
  "Select BUFFER's Vi state after upstream initializes a new buffer."
  ;; Lem runs switch hooks before it changes the window buffer.  Its Vi hook
  ;; initializes a new target to NORMAL but, because the target is not current
  ;; yet, leaves CURRENT-STATE unchanged.  This lower-weight hook observes that
  ;; initialized state and completes the synchronization.
  (when (typep (current-global-mode) 'lem-vi-mode/core:vi-mode)
    (alexandria:when-let ((state (lem-vi-mode/core:buffer-state buffer)))
      (unless (eq state (lem-vi-mode/core:current-state))
        (setf (lem-vi-mode/core:current-state) state)))))

(defun install-lem-yath-buffer-state-hook ()
  (add-hook *switch-to-buffer-hook*
            'lem-yath-sync-vi-state-before-buffer-switch -100))

(defun uninstall-lem-yath-buffer-state-hook ()
  (remove-hook *switch-to-buffer-hook*
               'lem-yath-sync-vi-state-before-buffer-switch))

(add-hook lem-vi-mode/core:*enable-hook*
          'install-lem-yath-buffer-state-hook -100)
(add-hook lem-vi-mode/core:*disable-hook*
          'uninstall-lem-yath-buffer-state-hook -100)

(defun lem-yath-emacs-state-p (&optional (buffer (current-buffer)))
  (typep (lem-vi-mode/core:buffer-state buffer)
         'lem-yath-emacs-state))

(defun lem-yath-emacs-return-state (buffer)
  (let ((state (buffer-value buffer :lem-yath-emacs-return-state)))
    (if (and (typep state 'lem-vi-mode/core:vi-state)
             (not (typep state 'lem-yath-emacs-state))
             (or (not (typep state 'lem-vi-mode/visual:visual))
                 (buffer-mark-p buffer)))
        state
        (lem-vi-mode/core:ensure-state 'lem-vi-mode/states:normal))))

(define-command lem-yath-toggle-emacs-state () ()
  "Toggle Evil-compatible, buffer-local EMACS state with C-z."
  ;; OPERATOR is a dynamically scoped temporary state in Lem.  Persisting an
  ;; EMACS buffer state inside it would be undone only visually when the
  ;; operator unwinds, desynchronizing the buffer and active cursor/keymaps.
  (when (typep (lem-vi-mode/core:current-state)
               'lem-vi-mode/states:operator)
    (error 'lem-vi-mode/core:operator-abort))
  (let* ((buffer (current-buffer))
         (state (lem-vi-mode/core:buffer-state buffer)))
    (if (typep state 'lem-yath-emacs-state)
        (let ((return-state (lem-yath-emacs-return-state buffer)))
          (setf (lem-vi-mode/core:buffer-state buffer) return-state)
          (buffer-unbound buffer :lem-yath-emacs-return-state))
        (progn
          (setf (buffer-value buffer :lem-yath-emacs-return-state)
                (or state
                    (lem-vi-mode/core:ensure-state
                     'lem-vi-mode/states:normal)))
          (setf (lem-vi-mode/core:buffer-state buffer)
                *lem-yath-emacs-state*)))))

;; Evil installs its toggle in motion and insert maps.  Motion covers normal,
;; visual, and operator states; replace inherits INSERT's state keymap.
(define-key lem-vi-mode:*motion-keymap* "C-z"
  'lem-yath-toggle-emacs-state)
(define-key lem-vi-mode:*insert-keymap* "C-z"
  'lem-yath-toggle-emacs-state)
(define-key *lem-yath-emacs-state-keymap* "C-z"
  'lem-yath-toggle-emacs-state)

;;; Emacs-state marks ---------------------------------------------------------

;; Vi's stock mark hooks enter VISUAL on mark activation and NORMAL on mark
;; cancellation.  Replace them with state-aware delegates so EMACS retains
;; ordinary Emacs regions while every other Vi state keeps upstream behavior.
(defun lem-yath-emacs-mark-activate (buffer)
  (unless (lem-yath-emacs-state-p buffer)
    (lem-vi-mode/visual::enable-visual-from-hook buffer)))

(defun lem-yath-emacs-mark-deactivate (buffer)
  (unless (lem-yath-emacs-state-p buffer)
    (lem-vi-mode/visual::disable-visual-from-hook buffer)))

(defun install-lem-yath-emacs-mark-hooks ()
  (remove-hook *buffer-mark-activate-hook*
               'lem-vi-mode/visual::enable-visual-from-hook)
  (remove-hook *buffer-mark-deactivate-hook*
               'lem-vi-mode/visual::disable-visual-from-hook)
  (add-hook *buffer-mark-activate-hook* 'lem-yath-emacs-mark-activate)
  (add-hook *buffer-mark-deactivate-hook* 'lem-yath-emacs-mark-deactivate))

(defun uninstall-lem-yath-emacs-mark-hooks ()
  (remove-hook *buffer-mark-activate-hook* 'lem-yath-emacs-mark-activate)
  (remove-hook *buffer-mark-deactivate-hook* 'lem-yath-emacs-mark-deactivate))

(add-hook lem-vi-mode/core:*enable-hook*
          'install-lem-yath-emacs-mark-hooks -100)
(add-hook lem-vi-mode/core:*disable-hook*
          'uninstall-lem-yath-emacs-mark-hooks -100)

(when (typep (current-global-mode) 'lem-vi-mode/core:vi-mode)
  (install-lem-yath-emacs-mark-hooks)
  (install-lem-yath-buffer-state-hook))

(defun emacs-region-mode ()
  (ensure-mode-object 'lem-core::emacs-mode))

(defmethod check-marked-using-global-mode :around
    ((global-mode lem-vi-mode/core:vi-mode) buffer)
  (if (lem-yath-emacs-state-p buffer)
      (check-marked-using-global-mode (emacs-region-mode) buffer)
      (call-next-method)))

(defmethod region-beginning-using-global-mode :around
    ((global-mode lem-vi-mode/core:vi-mode) &optional (buffer (current-buffer)))
  (if (lem-yath-emacs-state-p buffer)
      (region-beginning-using-global-mode (emacs-region-mode) buffer)
      (call-next-method)))

(defmethod region-end-using-global-mode :around
    ((global-mode lem-vi-mode/core:vi-mode) &optional (buffer (current-buffer)))
  (if (lem-yath-emacs-state-p buffer)
      (region-end-using-global-mode (emacs-region-mode) buffer)
      (call-next-method)))

(defmethod set-region-point-using-global-mode :around
    ((global-mode lem-vi-mode/core:vi-mode) (start point) (end point))
  (if (lem-yath-emacs-state-p)
      (set-region-point-using-global-mode (emacs-region-mode) start end)
      (call-next-method)))

(defmethod make-region-overlays-using-global-mode :around
    ((global-mode lem-vi-mode/core:vi-mode) cursor)
  (if (lem-yath-emacs-state-p (point-buffer cursor))
      (make-region-overlays-using-global-mode (emacs-region-mode) cursor)
      (call-next-method)))

(defun restore-terminal-cursor-profile ()
  "Leave the terminal with Lem's default steady box cursor."
  (set-attribute 'cursor
                 :background lem-vi-mode/core:*default-cursor-color*)
  (lem-if:update-cursor-shape (lem:implementation) :box))

;; Run after ordinary exit hooks so no later cleanup leaves a modal shape in
;; the invoking shell.
(add-hook *exit-editor-hook* 'restore-terminal-cursor-profile -100)

(remove-hook *after-load-theme-hook* 'configure-lem-yath-cursor-states)
(add-hook *after-load-theme-hook* 'configure-lem-yath-cursor-states -100)

(configure-lem-yath-cursor-states)
