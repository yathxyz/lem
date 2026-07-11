;;;; Corfu/Cape-style automatic completion for ordinary buffers.
;;;;
;;;; The live Emacs configuration opens Corfu after a three-character prefix
;;;; and 0.2 seconds, displays at most ten rows, and does not cycle at the
;;;; boundaries.  Mode-local Lem completion remains authoritative.  When no
;;;; such provider exists, same-major-mode dabbrev and file-at-point sources
;;;; mirror the configured Cape fallback order.

(in-package :lem-yath)

(defparameter *auto-completion-prefix-length* 3)
(defparameter *auto-completion-delay-ms* 200)
(defparameter *auto-completion-max-display-items* 10)

(defvar *auto-completion-timer* nil)
(defvar *auto-completion-generation* 0)
(defvar *auto-completion-context* nil)

(defparameter *auto-completion-continue-commands*
  '(lem/completion-mode::completion-self-insert
    lem/completion-mode::completion-delete-previous-char
    lem/completion-mode::completion-backward-delete-word
    lem/completion-mode::completion-next-line
    lem/completion-mode::completion-previous-line
    lem/completion-mode::completion-end-of-buffer
    lem/completion-mode::completion-beginning-of-buffer
    lem/completion-mode::completion-narrowing-down-or-next-line
    lem-yath-completion-space
    lem-yath-orderless-insert-separator
    lem-yath-act-completion))

(defun auto-completion-symbol-bounds (point)
  (with-point ((start point)
               (cursor point)
               (end point))
    (skip-chars-backward start #'syntax-symbol-char-p)
    (skip-chars-forward end #'syntax-symbol-char-p)
    (values start end (points-to-string start cursor))))

(defun auto-completion-symbol-prefix-length (point)
  (multiple-value-bind (start end prefix)
      (auto-completion-symbol-bounds point)
    (declare (ignore start end))
    (length prefix)))

(defun auto-completion-file-character-p (character)
  (or (alphanumericp character)
      (find character "-@~/_.${}#%,:" :test #'char=)))

(defun auto-completion-file-context (point)
  "Return file input and its replaceable final-component range at POINT.

Like Cape, require either an explicit `file:' prefix or a slash whose parent
directory already exists."
  (with-point ((bounds-start point)
               (path-start point)
               (replace-start point)
               (cursor point)
               (end point))
    (skip-chars-backward bounds-start #'auto-completion-file-character-p)
    (skip-chars-forward
     end
     (lambda (character)
       (and (auto-completion-file-character-p character)
            (char/= character #\/))))
    (let* ((token (points-to-string bounds-start cursor))
           (explicit-prefix-p
             (and (<= 5 (length token))
                  (string-equal "file:" token :end2 5)))
           (path-offset (if explicit-prefix-p 5 0)))
      (move-point path-start bounds-start)
      (character-offset path-start path-offset)
      (let* ((input (points-to-string path-start cursor))
             (expanded (ignore-errors
                         (expand-file-name input (buffer-directory))))
             (parent (and expanded (directory-namestring expanded)))
             (valid-p
               (or explicit-prefix-p
                   (and (find #\/ input)
                        parent
                        (uiop:directory-exists-p parent)))))
        (when valid-p
          (move-point replace-start cursor)
          (loop :while (point> replace-start path-start)
                :do (character-offset replace-start -1)
                :until (char= (character-at replace-start) #\/))
          (when (and (point< replace-start end)
                     (char= (character-at replace-start) #\/))
            (character-offset replace-start 1))
          (values input replace-start end))))))

(defun auto-completion-file-context-p (point)
  (not (null (nth-value 0 (auto-completion-file-context point)))))

(defun auto-completion-same-mode-buffers (buffer)
  (cons buffer
        (loop :for other :in (buffer-list)
              :unless (eq other buffer)
                :when (eq (buffer-major-mode other)
                          (buffer-major-mode buffer))
                  :collect other)))

(defun auto-completion-dabbrev-words (point prefix)
  (let* ((buffer (point-buffer point))
         (buffers (auto-completion-same-mode-buffers buffer))
         (words
           (append
            (lem/abbrev::collect-buffer-words-order-proximity point)
            (mapcan #'lem/abbrev::scan-buffer-words (rest buffers)))))
    (remove-duplicates
     (remove-if
      (lambda (word)
        (string-equal prefix word))
      words)
     :test #'string-equal)))

(defun auto-completion-dabbrev-items (point)
  (multiple-value-bind (start end prefix)
      (auto-completion-symbol-bounds point)
    (when (>= (length prefix) *auto-completion-prefix-length*)
      (mapcar
       (lambda (word)
         (lem/completion-mode:make-completion-item
          :label word
          :filter-text word
          :insert-text word
          :detail "Dabbrev"
          :start start
          :end end))
       (auto-completion-dabbrev-words point prefix)))))

(defun auto-completion-file-items (point)
  (multiple-value-bind (input start end)
      (auto-completion-file-context point)
    (when input
      (mapcar
       (lambda (filename)
         (let ((label (tail-of-pathname filename)))
           (lem/completion-mode:make-completion-item
            :label label
            :filter-text label
            :insert-text label
            :detail "File"
            :start start
            :end end)))
       (ignore-errors
         (completion-file input (buffer-directory)))))))

(defun auto-completion-primary-spec (&optional (buffer (current-buffer)))
  (variable-value 'lem/language-mode:completion-spec :buffer buffer))

(defun auto-completion-provider (&optional (point (current-point)))
  (or (auto-completion-primary-spec (point-buffer point))
      (if (auto-completion-file-context-p point)
          #'auto-completion-file-items
          #'auto-completion-dabbrev-items)))

(defun auto-completion-prefix-ready-p (point)
  (if (auto-completion-primary-spec (point-buffer point))
      (>= (auto-completion-symbol-prefix-length point)
          *auto-completion-prefix-length*)
      (or (>= (auto-completion-symbol-prefix-length point)
              *auto-completion-prefix-length*)
          (auto-completion-file-context-p point))))

(defun auto-completion-prompt-active-p ()
  (not (null (lem/prompt-window:current-prompt-window))))

(defun auto-completion-context-options (spec)
  "Apply Orderless only to ordinary, non-file in-buffer completion."
  (declare (ignore spec))
  (unless (or (auto-completion-prompt-active-p)
              (and (null (auto-completion-primary-spec))
                   (auto-completion-file-context-p (current-point))))
    (list :filter-function #'orderless-filter-completion-items
          :separator #\Space)))

(setf (variable-value
       'lem/completion-mode:completion-context-options-function :global)
      #'auto-completion-context-options)

(defun auto-completion-insert-state-p (buffer)
  (or (not (mode-active-p buffer 'lem-vi-mode:vi-mode))
      (let ((state (lem-vi-mode/core:current-state)))
        (and (typep state 'lem-vi-mode:insert)
             ;; REPLACE inherits INSERT's keymap, but completion's fallback
             ;; command does not participate in Vi's overwrite pre-command
             ;; path.  Keep the popup out of replacement sessions entirely.
             (not (typep state 'lem-vi-mode/states:replace-state))))))

(defun auto-completion-eligible-p ()
  (let ((buffer (current-buffer)))
    (and (null lem/completion-mode::*completion-context*)
         (not (auto-completion-prompt-active-p))
         (not (buffer-read-only-p buffer))
         (not (key-recording-p))
         (not lem/kbdmacro::*macro-running-p*)
         (auto-completion-insert-state-p buffer)
         (auto-completion-prefix-ready-p (current-point)))))

(defun auto-completion-trigger-command-p (command)
  (or (typep command 'self-insert)
      (member (command-name command)
              '(delete-previous-char
                lem/completion-mode::completion-self-insert
                lem/completion-mode::completion-delete-previous-char
                lem/completion-mode::completion-backward-delete-word))))

(defun auto-completion-continue-command-p (command)
  (member (command-name command) *auto-completion-continue-commands*))

(defun auto-completion-cancel-timer ()
  (incf *auto-completion-generation*)
  (when *auto-completion-timer*
    (ignore-errors (stop-timer *auto-completion-timer*))
    (setf *auto-completion-timer* nil)))

(defun auto-completion-context-pending-p ()
  (and *auto-completion-context*
       (eq *auto-completion-context*
           lem/completion-mode::*completion-context*)
       (lem/completion-mode::context-request-pending-p
        *auto-completion-context*)
       (null (lem/completion-mode::context-popup-menu
              *auto-completion-context*))))

(defun auto-completion-owned-context-p ()
  (and *auto-completion-context*
       (eq *auto-completion-context*
           lem/completion-mode::*completion-context*)))

(defun auto-completion-prune-context ()
  (unless (eq *auto-completion-context*
              lem/completion-mode::*completion-context*)
    (setf *auto-completion-context* nil)))

(defun auto-completion-snapshot-valid-p
    (timer generation window buffer tick position)
  (and (eq timer *auto-completion-timer*)
       (= generation *auto-completion-generation*)
       (eq window (current-window))
       (eq buffer (current-buffer))
       (= tick (buffer-modified-tick buffer))
       (= position (position-at-point (current-point)))
       (auto-completion-eligible-p)))

(defun auto-completion-fire
    (timer generation window buffer tick position)
  (when (and (eq timer *auto-completion-timer*)
             (= generation *auto-completion-generation*))
    (let ((queued-p (plusp (event-queue-length)))
          (valid-p (auto-completion-snapshot-valid-p
                    timer generation window buffer tick position)))
      ;; A one-shot timer is no longer pending even when its snapshot became
      ;; invalid.  Do not retain an expired object in global state.
      (setf *auto-completion-timer* nil)
      (cond
        ;; Lem has no `while-no-input'.  Do not query a provider ahead of an
        ;; already queued key or editor event.  A replacement timer is safe: a
        ;; queued command will invalidate it from the post-command hook.
        (queued-p
         (when valid-p
           (auto-completion-schedule)))
        (valid-p
         (handler-case
             (let ((context
                     (lem/completion-mode:run-completion
                      (auto-completion-provider)
                      :automatic t
                      :max-display-items *auto-completion-max-display-items*
                      :cycle nil)))
               (setf *auto-completion-context*
                     (and
                      (eq context lem/completion-mode::*completion-context*)
                      context)))
           (error (condition)
             (setf *auto-completion-context* nil)
             (message "Automatic completion failed: ~a" condition))))))))

(defun auto-completion-schedule ()
  (when (auto-completion-eligible-p)
    (let* ((generation *auto-completion-generation*)
           (window (current-window))
           (buffer (current-buffer))
           (tick (buffer-modified-tick buffer))
           (position (position-at-point (current-point)))
           (timer nil))
      (setf timer
            (make-timer
             (lambda ()
               (auto-completion-fire
                timer generation window buffer tick position))
             :name "lem-yath automatic completion"))
      (setf *auto-completion-timer* timer)
      (start-timer timer *auto-completion-delay-ms* :repeat nil))))

(defun auto-completion-post-command ()
  "Debounce completion after ordinary insertion and backward deletion."
  (auto-completion-cancel-timer)
  (let ((command-name (command-name (this-command))))
    (when (and
           (auto-completion-owned-context-p)
           (or (not (auto-completion-continue-command-p (this-command)))
               (and
                (auto-completion-context-pending-p)
                (not (member
                      command-name
                      '(lem/completion-mode::completion-self-insert
                        lem/completion-mode::completion-delete-previous-char
                        lem/completion-mode::completion-backward-delete-word))))))
      (lem/completion-mode:completion-end)))
  (auto-completion-prune-context)
  (when (and (null lem/completion-mode::*completion-context*)
             (auto-completion-trigger-command-p (this-command)))
    (auto-completion-schedule)))

(add-hook *post-command-hook* 'auto-completion-post-command -100)
(add-hook *exit-editor-hook* 'auto-completion-cancel-timer)

(define-command lem-yath-orderless-insert-separator () ()
  "Insert Corfu's separator and switch the current batch to local filtering."
  (if (lem/completion-mode:completion-start-local-filtering #\Space)
      (progn
        (insert-character (current-point) #\Space)
        (lem/completion-mode:completion-refresh))
      (lem-yath-completion-space)))

(define-key lem/completion-mode::*completion-mode-keymap*
  "M-Space" 'lem-yath-orderless-insert-separator)
