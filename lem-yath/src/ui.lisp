;;;; UI baseline: relative programming line numbers, truncated long lines,
;;;; no implicit tab/header row, no global current-line highlight, and
;;;; syntax-aware rainbow delimiters in programming buffers.  The palette
;;;; lives in theme.lisp.

(in-package :lem-yath)

(setf (variable-value 'line-wrap :global) nil)
(setf (variable-value 'highlight-line :global) nil)

(setf lem/line-numbers:*relative-line* t)
(setf (variable-value 'lem/line-numbers:line-numbers :global) t)

(defparameter *rainbow-delimiter-attributes*
  #(lem-lisp-mode/paren-coloring:paren-color-1
    lem-lisp-mode/paren-coloring:paren-color-2
    lem-lisp-mode/paren-coloring:paren-color-3
    lem-lisp-mode/paren-coloring:paren-color-4
    lem-lisp-mode/paren-coloring:paren-color-5
    lem-lisp-mode/paren-coloring:paren-color-6
    rainbow-delimiter-color-7
    rainbow-delimiter-color-8
    rainbow-delimiter-color-9))

(defun rainbow-delimiter-attribute (depth)
  (aref *rainbow-delimiter-attributes*
        (mod (max 0 depth) (length *rainbow-delimiter-attributes*))))

(defun rainbow-delimiter-code-p (point)
  (not (in-string-or-comment-p point)))

(defun rainbow-delimiter-coloring (start end)
  "Color syntax-table delimiters by nesting depth in programming buffers."
  (let* ((buffer (point-buffer start))
         (syntax-table (buffer-syntax-table buffer))
         (pairs (and syntax-table
                     (lem/buffer/syntax-table:syntax-table-paren-pairs
                      syntax-table))))
    (when (and pairs (programming-buffer-p buffer))
      (with-point ((point start)
                   (limit end)
                   (property-end start))
        (line-start point)
        (line-end limit)
        (let ((depth
                (lem/buffer/internal::pps-state-paren-depth
                 (syntax-ppss point))))
          (loop :while (point< point limit)
                :for character := (character-at point)
                :for opening := (assoc character pairs)
                :for closing := (rassoc character pairs)
                :do (cond
                      ((and opening (rainbow-delimiter-code-p point))
                       (move-point property-end point)
                       (character-offset property-end 1)
                       (put-text-property
                        point property-end :attribute
                        (rainbow-delimiter-attribute depth))
                       (incf depth))
                      ((and closing (rainbow-delimiter-code-p point))
                       (setf depth (max 0 (1- depth)))
                       (move-point property-end point)
                       (character-offset property-end 1)
                       (put-text-property
                        point property-end :attribute
                        (rainbow-delimiter-attribute depth))))
                    (character-offset point 1)))))))

;; Upstream's hook is hard-coded to Common Lisp and round parentheses.  Own
;; one generic hook instead, including after a live configuration reload.
(setf (variable-value
       'lem-lisp-mode/paren-coloring:paren-coloring :global) nil)
(remove-hook (variable-value 'after-syntax-scan-hook :global)
             'lem-lisp-mode/paren-coloring:paren-coloring)
(add-hook (variable-value 'after-syntax-scan-hook :global)
          'rainbow-delimiter-coloring)

(defun programming-line-number-content (buffer point)
  (multiple-value-bind (computed-line active-line-p)
      (lem/line-numbers::compute-line buffer point)
    (let* ((number-format
             (or (variable-value 'lem/line-numbers:line-number-format
                                 :default buffer)
                 (lem/line-numbers::get-buffer-num-format buffer)))
           (string (format nil number-format computed-line))
           (attribute
             (if active-line-p
                 `((0 ,(length string)
                      lem/line-numbers:active-line-number-attribute))
                 `((0 ,(length string)
                      lem/line-numbers:line-numbers-attribute)))))
      (lem/buffer/line:make-content :string string
                                    :attributes attribute))))

(defun join-left-display-content (left right)
  "Concatenate two independent left-gutter providers without losing faces."
  (cond
    ((null left) right)
    ((null right) left)
    (t
     (let* ((left-string (lem/buffer/line:content-string left))
            (right-string (lem/buffer/line:content-string right))
            (right-attributes
              (lem/buffer/line:offset-elements
               (lem/buffer/line:content-attributes right)
               (length left-string))))
       (lem/buffer/line:make-content
        :string (concatenate 'string left-string right-string)
        :attributes (append (lem/buffer/line:content-attributes left)
                            right-attributes))))))

;; Lem's synthesized active-mode class selects just one primary gutter method.
;; Make the line-number primary delegate, then compose its contribution in an
;; around method so providers on either side of it in the mode order survive.
(defmethod compute-left-display-area-content
    ((mode lem/line-numbers::line-numbers-mode) buffer point)
  (declare (ignore mode buffer point))
  (call-next-method))

(defmethod compute-left-display-area-content :around
    ((mode lem/line-numbers::line-numbers-mode) buffer point)
  (declare (ignore mode))
  (let ((other-content (call-next-method)))
    (if (programming-buffer-p buffer)
        (join-left-display-content
         other-content
         (programming-line-number-content buffer point))
        other-content)))

;; Emacs retains its built-in C-x t prefix but does not enable tab-bar-mode at
;; startup.  Lem's extension registers an unconditional after-init enable hook,
;; so remove it and turn off any live header when this config is reloaded.
(defun enable-lem-yath-frame-multiplexer-on-demand ()
  (unless (variable-value 'lem/frame-multiplexer::frame-multiplexer :global)
    (uiop:symbol-call :lem/frame-multiplexer :enable-frame-multiplexer)))

(define-command lem-yath-frame-create () ()
  "Enable frame tabs and create a new tab with a fresh buffer list."
  (enable-lem-yath-frame-multiplexer-on-demand)
  (call-command
   'lem/frame-multiplexer:frame-multiplexer-create-with-new-buffer-list nil))

(define-command lem-yath-frame-create-with-previous-buffer () ()
  "Enable frame tabs and create a new tab showing the current buffer."
  (enable-lem-yath-frame-multiplexer-on-demand)
  (call-command
   'lem/frame-multiplexer::frame-multiplexer-create-with-previous-buffer nil))

(defun configure-lem-yath-frame-multiplexer ()
  (let* ((package (find-package :lem/frame-multiplexer))
         (keymap-symbol (and package (find-symbol "*KEYMAP*" package)))
         (enable-symbol (and package
                             (find-symbol "ENABLE-FRAME-MULTIPLEXER" package)))
         (upstream-autostart-p
           (and enable-symbol
                (find enable-symbol *after-init-hook* :key #'car))))
    (unless (and keymap-symbol (boundp keymap-symbol))
      (error "The pinned frame-multiplexer keymap is unavailable"))
    ;; C-z is Evil's state toggle.  C-x t is Emacs' native tab-bar prefix.
    (define-key *global-keymap* "C-x t" (symbol-value keymap-symbol))
    (define-key (symbol-value keymap-symbol) "2" 'lem-yath-frame-create)
    (define-key (symbol-value keymap-symbol) "c" 'lem-yath-frame-create)
    (define-key (symbol-value keymap-symbol) "C"
      'lem-yath-frame-create-with-previous-buffer)
    (remove-hook *after-init-hook* enable-symbol)
    ;; When this configuration is first loaded after upstream's init hook has
    ;; already run, undo that automatic tab row.  On later reloads the hook is
    ;; gone, so preserve tabs the user explicitly enabled with C-x t 2.
    (when (and upstream-autostart-p
               (variable-value
                'lem/frame-multiplexer::frame-multiplexer :global))
      (uiop:symbol-call :lem/frame-multiplexer
                        :disable-frame-multiplexer))))

(configure-lem-yath-frame-multiplexer)
