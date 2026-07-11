;;;; UI: relative line numbers (display-line-numbers-type 'relative),
;;;; tab bar (tab-bar-mode), show-paren/highlight-line are Lem defaults.
;;;; The Emacs config loads no color theme by default, so neither do we.

(in-package :lem-yath)

(setf lem/line-numbers:*relative-line* t)
(setf (variable-value 'lem/line-numbers:line-numbers :global) t)

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

;; tab-bar-mode equivalent (tmux-like frame tabs). Enabling is idempotent on
;; reload and runs immediately for the flake's post-init --eval load path.
(defun enable-lem-yath-frame-multiplexer ()
  (let* ((package (find-package :lem/frame-multiplexer))
         (keymap-symbol (and package (find-symbol "*KEYMAP*" package))))
    (unless (and keymap-symbol (boundp keymap-symbol))
      (error "The pinned frame-multiplexer keymap is unavailable"))
    ;; C-z is Evil's state toggle.  C-x t is Emacs' native tab-bar prefix.
    (define-key *global-keymap* "C-x t" (symbol-value keymap-symbol))
    (uiop:symbol-call :lem/frame-multiplexer :enable-frame-multiplexer)))

(initialize-editor-feature 'enable-lem-yath-frame-multiplexer)
