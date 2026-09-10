(defpackage :lem-vi-mode/states
  (:use :cl
        :lem)
  (:import-from :alexandria
                :when-let
                :when-let*)
  (:import-from :lem-vi-mode/core
                :define-state
                :*enable-hook*
                :*disable-hook*
                :current-state
                :buffer-state
                :state-changed-hook
                :ensure-state
                :define-keymap)
  (:import-from :lem-vi-mode/modeline
                :state-modeline-yellow
                :state-modeline-aqua
                :state-modeline-green
                :state-modeline-orange
                :change-element-by-state)
  (:export :*normal-keymap*
           :*command-keymap*
           :*motion-keymap*
           :*insert-keymap*
           :*inactive-keymap*
           :*operator-keymap*
           :*replace-char-state-keymap*
           :*outer-text-objects-keymap*
           :*inner-text-objects-keymap*
           :normal
           :insert
           :operator
           :replace-state
           :replace-char-state))
(in-package :lem-vi-mode/states)

(defmethod state-changed-hook (state) :after
  (change-element-by-state state))

;;
;; Keymaps

(defvar *emacs-keymap* *global-keymap*)

(define-keymap *motion-keymap*)
(define-keymap *normal-keymap*)
(keymap-add-child *normal-keymap* *motion-keymap*)
(define-keymap *insert-keymap*)
(define-keymap *operator-keymap*)
(define-keymap *replace-char-state-keymap* :undef-hook 'return-last-read-char)
(define-keymap *outer-text-objects-keymap*)
(define-keymap *inner-text-objects-keymap*)

(define-symbol-macro *command-keymap*
  (progn
    (warn "*command-keymap* is deprecated. Use *normal-keymap* instead.")
    *normal-keymap*))

(defvar *inactive-keymap* (make-keymap))

(define-command return-last-read-char () ()
  (key-to-char (first (lem-core:last-read-key-sequence))))

;;
;; Normal state

(define-state normal () ()
  (:default-initargs
   :name "NORMAL"
   :cursor-type :box
   :modeline-color 'state-modeline-yellow
   :keymaps (list *normal-keymap*)))

;;
;; Insert state

(define-state insert () ()
  (:default-initargs
   :name "INSERT"
   :cursor-type :bar
   :modeline-color 'state-modeline-aqua
   :keymaps (list *insert-keymap*)))

;;
;; Replace state

(define-state replace-state (insert) ()
  (:default-initargs
   :name "REPLACE"
   :cursor-type :underline
   :modeline-color 'state-modeline-orange))

;;
;; Ex state

(define-state vi-modeline () ()
  (:default-initargs
   :name "COMMAND"
   :modeline-color 'state-modeline-green
   :keymaps (list *inactive-keymap*)))

;;
;; Operator-pending state

(define-state operator (normal) ()
  (:default-initargs
   :cursor-type :underline
   :keymaps (list *operator-keymap* *normal-keymap*)))

;;
;; Replace char state

(define-state replace-char-state (normal) ()
  (:default-initargs
   :cursor-type :underline
   :keymaps (list *replace-char-state-keymap*)))

;;
;; Setup hooks

(defun enter-prompt ()
  (setf (buffer-state) 'vi-modeline))
(defun exit-prompt ()
  (when-let* ((cb (window-buffer (current-window)))
              (state (buffer-state cb)))
   (setf (current-state) state)))

(defun vi-switch-to-buffer (&optional (buffer (current-buffer)))
  (let ((buffer-state (buffer-state buffer)))
    (if buffer-state
        (setf (current-state) buffer-state)
        (let ((n (ensure-state 'normal)))
          (setf (buffer-state buffer) n)))))

(defun vi-switch-to-window (old new)
  (declare (ignore old))
  (when-let ((state (buffer-state (window-buffer new))))
    (setf (current-state) state)))

(defun vi-activate-frame (old new)
  ;; A redisplay visit is a context switch, not an editing action. Preserve a
  ;; pending operator's temporary state as well as the buffer's regular state.
  (when old
    (let* ((window (frame-current-window old))
           (buffer (and window (window-buffer window))))
      (when (and buffer (mode-active-p buffer 'lem-vi-mode/core:vi-mode))
        (setf (window-parameter window 'vi-frame-context)
              (list buffer (buffer-state buffer) (current-state)
                    lem-vi-mode/core::*current-main-state*)))))
  (let* ((window (frame-current-window new))
         (buffer (window-buffer window))
         (saved (window-parameter window 'vi-frame-context)))
    (when (mode-active-p buffer 'lem-vi-mode/core:vi-mode)
      (if (and (eq buffer (first saved)) (eq (buffer-state buffer) (second saved)))
          (setf (current-state) (third saved)
                lem-vi-mode/core::*current-main-state* (fourth saved))
          (setf (current-state) (or (buffer-state buffer) (ensure-state 'normal))
                lem-vi-mode/core::*current-main-state* nil)))))

(defun vi-enable-hook ()
  (setf *region-end-offset* -1)
  (setf (current-state) (or (buffer-state (current-buffer)) (ensure-state 'normal)))
  (add-hook *switch-to-buffer-hook* 'vi-switch-to-buffer)
  (add-hook *switch-to-window-hook* 'vi-switch-to-window)
  (add-hook *activate-frame-hook* 'vi-activate-frame)
  (add-hook *prompt-after-activate-hook* 'enter-prompt)
  (add-hook *prompt-deactivate-hook* 'exit-prompt))

(defun vi-disable-hook ()
  (setf *region-end-offset* 0)
  (remove-hook *switch-to-buffer-hook* 'vi-switch-to-buffer)
  (remove-hook *switch-to-window-hook* 'vi-switch-to-window)
  (remove-hook *activate-frame-hook* 'vi-activate-frame)
  (remove-hook *prompt-after-activate-hook* 'enter-prompt)
  (remove-hook *prompt-deactivate-hook* 'exit-prompt))

(add-hook *enable-hook* 'vi-enable-hook)
(add-hook *disable-hook* 'vi-disable-hook)
