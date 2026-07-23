;;;; Evil Collection-style interaction for Lem's libvterm terminal.
;;;;
;;;; Keep this separate from the general Vi configuration: terminal input is a
;;;; process protocol, not an editable Lem buffer.  The copy-mode major mode
;;;; supplies safe Normal-state navigation while the terminal object remains
;;;; live, and terminal-mode supplies raw Insert-state input.

(in-package :lem-yath)

(defvar *lem-yath-terminal-input-keymap*
  (make-keymap :description "lem-yath terminal input"))

(defvar *lem-yath-terminal-normal-keymap*
  (make-keymap :description "lem-yath terminal normal"))

(defun lem-yath-terminal-object ()
  (or (lem-terminal/terminal-mode::get-current-terminal)
      (editor-error "The current buffer has no live terminal")))

(defun lem-yath-terminal-send-escape-p (&optional (buffer (current-buffer)))
  (not (null (buffer-value buffer :lem-yath-terminal-send-escape-p))))

(defun (setf lem-yath-terminal-send-escape-p) (value
                                                &optional
                                                  (buffer (current-buffer)))
  (setf (buffer-value buffer :lem-yath-terminal-send-escape-p)
        (not (null value))))

(defun lem-yath-terminal-live-normal-view (terminal)
  "Keep TERMINAL output live while its read-only buffer uses Normal state."
  ;; Upstream copy mode pauses rendering.  Evil's vterm Normal state does not,
  ;; so retain the read-only major mode/keymaps but resume terminal rendering.
  (lem-terminal/terminal:copy-mode-off terminal))

(define-command lem-yath-terminal-enter-normal () ()
  "Enter a live, read-only terminal view in Vi Normal state."
  (let ((terminal (lem-yath-terminal-object)))
    (lem-terminal/terminal-mode::terminal-copy-mode)
    (lem-terminal/terminal:activate-scrollback terminal)
    (lem-yath-terminal-live-normal-view terminal)
    (setf (lem-vi-mode/core:buffer-state)
          'lem-vi-mode/states:normal)))

(define-command lem-yath-terminal-enter-insert () ()
  "Return to the live terminal cursor and raw Vi Insert-state input."
  (let ((terminal (lem-yath-terminal-object)))
    (lem-terminal/terminal:deactivate-scrollback terminal)
    (lem-terminal/terminal-mode::terminal-copy-mode-off)
    (lem-terminal/terminal:adjust-point terminal)
    (setf (lem-vi-mode/core:buffer-state)
          'lem-vi-mode/states:insert)))

(define-command lem-yath-terminal-escape () ()
  "Send Escape to the child or enter Normal state, as configured locally."
  (if (lem-yath-terminal-send-escape-p)
      (lem-terminal/terminal:input-key
       (lem-yath-terminal-object)
       lem-terminal/ffi::vterm_key_escape)
      (lem-yath-terminal-enter-normal)))

(define-command lem-yath-terminal-toggle-send-escape () ()
  "Toggle whether Insert-state Escape is sent to the terminal process."
  (setf (lem-yath-terminal-send-escape-p)
        (not (lem-yath-terminal-send-escape-p)))
  (message "Sending ESC to ~A."
           (if (lem-yath-terminal-send-escape-p)
               "vterm"
               "emacs")))

(define-command lem-yath-terminal-normal-escape () ()
  "Remain in terminal Normal state."
  (setf (lem-vi-mode/core:buffer-state)
        'lem-vi-mode/states:normal))

(define-command lem-yath-terminal-submit () ()
  "Send Return to the child while remaining in terminal Normal state."
  (let ((terminal (lem-yath-terminal-object)))
    (lem-terminal/terminal:deactivate-scrollback terminal)
    (lem-terminal/terminal:adjust-point terminal)
    (lem-terminal/terminal:input-key terminal
                                     lem-terminal/ffi::vterm_key_enter)))

(defun lem-yath-terminal-paste-string ()
  "Return the current clipboard or kill-ring text, if any."
  (yank-from-clipboard-or-killring))

(define-command lem-yath-terminal-paste (&optional (count 1)) (:universal)
  "Send the current clipboard or kill-ring text to the terminal COUNT times."
  (let ((terminal (lem-yath-terminal-object))
        (text (lem-yath-terminal-paste-string)))
    (when text
      (lem-terminal/terminal:deactivate-scrollback terminal)
      (lem-terminal/terminal:adjust-point terminal)
      (loop :repeat (max 0 count)
            :do
               (loop :for character :across text
                     :do (lem-terminal/terminal:input-character
                          terminal character))))))

(define-command vterm (always-create-terminal-p) (:universal-nil)
  "Open Lem's libvterm terminal under the familiar Emacs command name."
  (lem-terminal/terminal-mode::terminal always-create-terminal-p))

;; These maps must precede Vi's state maps.  In raw mode the terminal execute
;; method turns every non-bypassed command back into its physical key sequence,
;; preserving shell controls such as C-u and C-w.
(define-key *lem-yath-terminal-input-keymap* "Escape"
  'lem-yath-terminal-escape)
(define-key *lem-yath-terminal-input-keymap* "C-x ["
  'lem-yath-terminal-enter-normal)
(define-key *lem-yath-terminal-input-keymap* "C-c C-z"
  'lem-yath-terminal-toggle-send-escape)

(define-key *lem-yath-terminal-normal-keymap* "Escape"
  'lem-yath-terminal-normal-escape)
(define-key *lem-yath-terminal-normal-keymap* "C-x ["
  'lem-yath-terminal-enter-normal)
(define-key *lem-yath-terminal-normal-keymap* "C-c C-z"
  'lem-yath-terminal-toggle-send-escape)
(define-key *lem-yath-terminal-normal-keymap* "Return"
  'lem-yath-terminal-submit)
(dolist (key '("i" "I" "a" "A"))
  (define-key *lem-yath-terminal-normal-keymap* key
    'lem-yath-terminal-enter-insert))
(dolist (key '("p" "P"))
  (define-key *lem-yath-terminal-normal-keymap* key
    'lem-yath-terminal-paste))

(defmethod lem-vi-mode/core:mode-specific-keymaps
    ((mode lem-terminal/terminal-mode::terminal-mode))
  (declare (ignore mode))
  (list *lem-yath-terminal-input-keymap*))

(defmethod lem-vi-mode/core:mode-specific-keymaps
    ((mode lem-terminal/terminal-mode::terminal-copy-mode))
  (declare (ignore mode))
  (list *lem-yath-terminal-normal-keymap*))

(defun lem-yath-terminal-initialize-vi-state (buffer)
  "Give terminal BUFFER the Evil Collection state matching its major mode."
  (when (typep (current-global-mode) 'lem-vi-mode/core:vi-mode)
    (case (buffer-major-mode buffer)
      (lem-terminal/terminal-mode::terminal-mode
       (setf (lem-vi-mode/core:buffer-state buffer)
             'lem-vi-mode/states:insert))
      (lem-terminal/terminal-mode::terminal-copy-mode
       (setf (lem-vi-mode/core:buffer-state buffer)
             'lem-vi-mode/states:normal)))))

(remove-hook *switch-to-buffer-hook*
             'lem-yath-terminal-initialize-vi-state)
(add-hook *switch-to-buffer-hook*
          'lem-yath-terminal-initialize-vi-state 50)

;; Upstream terminal-mode deliberately raw-sends commands unless they are in
;; this list.  Register only the control commands that must alter editor state.
(dolist (command '(lem-yath-terminal-enter-normal
                   lem-yath-terminal-enter-insert
                   lem-yath-terminal-escape
                   lem-yath-terminal-toggle-send-escape
                   vterm))
  (pushnew command lem-terminal/terminal-mode::*bypass-commands*))
