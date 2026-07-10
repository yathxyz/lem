;;;; Global electric-pair and delete-selection behavior.
;;;;
;;;; The Emacs configuration enables `electric-pair-mode' and
;;;; `delete-selection-mode'.  Openers wrap a non-Vi active region instead of
;;;; deleting it; ordinary self insertion replaces that region.  Vi visual
;;;; state keeps its modal key grammar, and Paredit remains authoritative in
;;;; Lisp-family buffers.

(in-package :lem-yath)

(defun electric-active-selection-p (&optional (point (current-point)))
  "Whether POINT owns a nonempty, self-insertable selection."
  (let ((mark (cursor-mark point)))
    (and (mark-active-p mark)
         (mark-point mark)
         (not (point= point (mark-point mark)))
         ;; Evil does not make printable keys self-inserting in VISUAL state.
         (not (and (typep (current-global-mode) 'lem-vi-mode:vi-mode)
                   (lem-vi-mode/visual:visual-p (point-buffer point)))))))

(defun electric-opening-close (character)
  "Return CHARACTER's syntax-table closer, including simple string quotes."
  (or (alexandria:when-let ((pair (syntax-open-paren-char-p character)))
        (cdr pair))
      (when (syntax-string-quote-char-p character)
        character)))

(defun electric-special-character-p (character)
  (or (electric-opening-close character)
      (syntax-closed-paren-char-p character)))

(defun electric-closing-character-p (character)
  (or (syntax-closed-paren-char-p character)
      (alexandria:when-let ((close (electric-opening-close character)))
        (char= character close))))

(defun electric-pair-whitespace-character-p (character)
  (find character '(#\Tab #\Space #\Newline) :test #'char=))

(defun electric-close-after-whitespace-p (point character)
  (let* ((state (syntax-ppss point))
         (container-start
           (and (pps-state-string-or-comment-p state)
                (pps-state-token-start-point state))))
    (with-point ((cursor point))
      (skip-chars-forward cursor #'electric-pair-whitespace-character-p)
      (let* ((cursor-state (syntax-ppss cursor))
             (cursor-container-start
               (and (pps-state-string-or-comment-p cursor-state)
                    (pps-state-token-start-point cursor-state))))
        (and (if container-start
                 (and cursor-container-start
                      (point= container-start cursor-container-start))
                 (null cursor-container-start))
             (eql (character-at cursor) character))))))

(defun electric-unmatched-close-after-whitespace-p (point character)
  (and (electric-close-after-whitespace-p point character)
       (let* ((state (syntax-ppss point))
              (open (car (pps-state-paren-stack state))))
         (if (pps-state-string-or-comment-p state)
             (let ((text-open
                     (car (syntax-closed-paren-char-p character)))
                   (depth 0))
               (with-point ((cursor (pps-state-token-start-point state)))
                 (loop :while (point< cursor point)
                       :for current = (character-at cursor)
                       :unless (syntax-escape-point-p cursor 0)
                         :do (cond
                               ((eql current text-open)
                                (incf depth))
                               ((and (eql current character)
                                     (plusp depth))
                                (decf depth)))
                       :do (character-offset cursor 1)))
               (zerop depth))
             (or (null open)
                 (not (syntax-equal-paren-p open character)))))))

(defun electric-unmatched-quote-after-whitespace-p (point character)
  (and (not (in-string-p point))
       (electric-close-after-whitespace-p point character)
       (with-point ((quote point)
                    (end (buffer-end-point (point-buffer point))))
         (skip-chars-forward quote #'electric-pair-whitespace-character-p)
         (let* ((state (syntax-ppss end))
                (start (and (pps-state-string-p state)
                            (pps-state-token-start-point state))))
           (and start (point= quote start))))))

(defun electric-skip-close-after-whitespace (point character)
  (when (electric-close-after-whitespace-p point character)
    (skip-chars-forward point #'electric-pair-whitespace-character-p)
    (character-offset point 1)
    t))

(defun electric-wrap-selection (point open close &optional (count 1))
  "Wrap POINT's active selection with COUNT copies of OPEN and CLOSE.

Electric Pair leaves point after the opener for delimiter pairs.  For quotes,
it leaves point on the original side of the region.  In either case the mark is
deactivated, matching delete-selection's consumed-region behavior."
  (let* ((mark (cursor-mark point))
         (point-at-start-p (point< point (mark-point mark))))
    (with-point ((outer-start (cursor-region-beginning point) :right-inserting)
                 (inner-start (cursor-region-beginning point) :left-inserting)
                 (outer-end (cursor-region-end point) :left-inserting))
      ;; Lem undo leaves point at the earliest edit it ultimately reverses.
      ;; Match Emacs's original point by making that edit orientation-dependent.
      (if point-at-start-p
          (progn
            (insert-character outer-start open count)
            (insert-character outer-end close count))
          (progn
            (insert-character outer-end close count)
            (insert-character outer-start open count)))
      (move-point point
                  (if (and (char= open close)
                           (not point-at-start-p))
                      outer-end
                      inner-start))
      (mark-cancel mark))))

(defun electric-escape-paredit-selection (start end)
  "Escape quotes and backslashes between START and END for a new Lisp string."
  (with-point ((cursor start :left-inserting))
    (loop :while (point< cursor end)
          :for character = (character-at cursor)
          :when (find character '(#\\ #\") :test #'char=)
            :do (insert-character cursor #\\)
          :do (character-offset cursor 1))))

(defun electric-paredit-wrap-selection (point open close)
  "Wrap POINT using the active-region behavior of configured Lispy.

Delimiter commands leave point on the opener and deactivate the mark.  Quote
commands retain an outer selection and its original orientation."
  (let* ((mark (cursor-mark point))
         (point-at-start-p (point< point (mark-point mark))))
    (with-point ((outer-start (cursor-region-beginning point) :right-inserting)
                 (content-start (cursor-region-beginning point) :left-inserting)
                 (content-end (cursor-region-end point) :right-inserting)
                 (outer-end (cursor-region-end point) :left-inserting))
      (if point-at-start-p
          (progn
            (insert-character outer-start open)
            (insert-character outer-end close))
          (progn
            (insert-character outer-end close)
            (insert-character outer-start open)))
      (cond
        ((char= open close)
         (electric-escape-paredit-selection content-start content-end)
         (if point-at-start-p
             (progn
               (move-point point outer-start)
               (mark-set-point mark outer-end))
             (progn
               (move-point point outer-end)
               (mark-set-point mark outer-start))))
        (t
         (move-point point outer-start)
         (mark-cancel mark))))))

(defun electric-replace-selection (point character count)
  "Replace POINT's active selection with COUNT copies of CHARACTER."
  (let ((mark (cursor-mark point)))
    (with-point ((start (cursor-region-beginning point) :left-inserting)
                 (end (cursor-region-end point) :right-inserting))
      (delete-between-points start end)
      (move-point point start))
    (mark-cancel mark)
    (insert-character point character count)))

(defun electric-opening-escaped-p (point character)
  (and (electric-opening-close character)
       (syntax-escape-point-p point 0)))

(defun electric-insert-one (point character)
  "Insert one CHARACTER at POINT with Emacs electric-pair semantics."
  (let ((close (electric-opening-close character)))
    (cond
      ((electric-active-selection-p point)
       (if close
           (electric-wrap-selection point character close)
           (electric-replace-selection point character 1)))
      ((electric-opening-escaped-p point character)
       (insert-character point character))
      ;; A same-character quote under point is a closer only from inside its
      ;; string.  Outside the string it is an opener and receives a fresh pair.
      ((and close
            (char= character close)
            (in-string-p point)
            (electric-skip-close-after-whitespace point character)))
      ;; A lone quote ahead can close this new opener.  A quote which already
      ;; opens a balanced string must receive a fresh pair instead.
      ((and close
            (char= character close)
            (electric-unmatched-quote-after-whitespace-p point character))
       (insert-character point character))
      ;; An existing matching delimiter closes the new opener; do not create a
      ;; duplicate.  Quotes are excluded because their role depends on syntax.
      ((and close
            (char/= character close)
            (electric-unmatched-close-after-whitespace-p point close))
       (insert-character point character))
      (close
       (insert-character point character)
       (insert-character point close)
       (character-offset point -1))
      ((and (syntax-closed-paren-char-p character)
            (electric-skip-close-after-whitespace point character)))
      (t
       (insert-character point character)))))

(defun electric-self-insert (character count)
  "Run one syntax-aware self insertion, preserving Lem's insert hooks."
  (run-hooks
   (variable-value 'lem-core/commands/edit:self-insert-before-hook)
   character)
  (let ((close (electric-opening-close character)))
    (cond
      ((and (electric-active-selection-p) close)
       (electric-wrap-selection (current-point) character close count))
      ((electric-active-selection-p)
       (electric-replace-selection (current-point) character count))
      ((and close (> count 1))
       (let ((remaining count))
         ;; A numeric self-insert evaluates escaping for its first character;
         ;; the remaining characters are ordinary electric openers.
         (when (syntax-escape-point-p (current-point) 0)
           (insert-character (current-point) character)
           (decf remaining))
         (when (plusp remaining)
           (let ((reuse-close-p
                   (if (char= character close)
                       (electric-unmatched-quote-after-whitespace-p
                        (current-point) close)
                       (electric-unmatched-close-after-whitespace-p
                        (current-point) close))))
             (insert-character (current-point) character remaining)
             (unless reuse-close-p
               (insert-character (current-point) close remaining)
               (character-offset (current-point) (- remaining)))))))
      (t
       (loop :repeat count
             :do (electric-insert-one (current-point) character)))))
  (run-hooks
   (variable-value 'lem-core/commands/edit:self-insert-after-hook)
   character))

;; Replace only the core insertion primitive.  The surrounding SELF-INSERT
;; command still runs Lem's editable/multi-cursor advice and every major-mode
;; before/after method (notably Lisp autodoc and unmatched-close checks).
(defmethod lem-core/commands/edit:process-input-character :around
    (character count)
  (if (and character
           (not (and (typep (current-global-mode) 'lem-vi-mode:vi-mode)
                     (typep (lem-vi-mode/core:current-state)
                            'lem-vi-mode/states:replace-state))))
      (electric-self-insert character count)
      (call-next-method)))

(defun electric-paredit-command (character)
  (case character
    (#\( 'lem-paredit-mode:paredit-insert-paren)
    (#\[ 'lem-paredit-mode:paredit-insert-bracket)
    (#\{ 'lem-paredit-mode:paredit-insert-brace)
    (#\" 'lem-paredit-mode:paredit-insert-doublequote)
    (#\| 'lem-paredit-mode:paredit-insert-vertical-line)
    (#\) 'lem-paredit-mode:paredit-close-parenthesis)
    (#\] 'lem-paredit-mode:paredit-close-bracket)
    (#\} 'lem-paredit-mode:paredit-close-brace)))

(defun electric-paredit-closing-command-p (command)
  (member command
          '(lem-paredit-mode:paredit-close-parenthesis
            lem-paredit-mode:paredit-close-bracket
            lem-paredit-mode:paredit-close-brace)))

(defun electric-execute-paredit-command (command)
  (execute
   (lem-core::get-active-modes-class-instance (current-buffer))
   (lem/common/command:ensure-command command)
   nil))

(defun electric-prompt-completion-p ()
  (alexandria:when-let ((prompt
                         (lem/prompt-window:current-prompt-window)))
    (eq (current-buffer) (window-buffer prompt))))

;; Completion's fallback command bypasses SELF-INSERT.  Delimiters still pair;
;; ordinary completion then closes, while an Orderless separator context
;; refilters its frozen batch.  In Lisp buffers, dispatch the same Paredit
;; command that its mode keymap owns so structural spacing remains intact.
(defmethod execute :around
    (mode (command lem/completion-mode::completion-self-insert) argument)
  (declare (ignore mode command argument))
  (let* ((character (insertion-key-p (last-read-key-sequence)))
         (paredit-command
           (and character
                (mode-active-p (current-buffer)
                               'lem-paredit-mode:paredit-mode)
                (electric-paredit-command character))))
    (cond
      ((or (null character)
           (and (typep (current-global-mode) 'lem-vi-mode:vi-mode)
                (typep (lem-vi-mode/core:current-state)
                       'lem-vi-mode/states:replace-state)))
       (call-next-method))
      ((electric-prompt-completion-p)
       (if (or (electric-active-selection-p)
               (electric-special-character-p character))
           (progn
             (electric-self-insert character 1)
             (lem/completion-mode:completion-refresh))
           (call-next-method)))
      ((and (lem/completion-mode:completion-local-filtering-p)
            (electric-closing-character-p character)
            (or (electric-paredit-closing-command-p paredit-command)
                (electric-close-after-whitespace-p
                 (current-point) character)))
       (lem/completion-mode:completion-end)
       (if paredit-command
           (electric-execute-paredit-command paredit-command)
           (electric-self-insert character 1)))
      ((and (lem/completion-mode:completion-local-filtering-p)
            (or paredit-command
                (electric-active-selection-p)
                (electric-special-character-p character)))
       (if paredit-command
           (electric-execute-paredit-command paredit-command)
           (electric-self-insert character 1))
       (lem/completion-mode:completion-refresh))
      ((or paredit-command
           (electric-active-selection-p)
           (electric-special-character-p character))
       (lem/completion-mode:completion-end)
       (if paredit-command
           (electric-execute-paredit-command paredit-command)
           (electric-self-insert character 1)))
      (t
       (call-next-method)))))

;; Paredit's insertion commands intentionally outrank the global self-insert
;; layer.  Add only the missing active-region wrapping case, then delegate every
;; ordinary Lisp insertion to upstream Paredit unchanged.
(defmacro define-electric-paredit-region-wrapper (command open close)
  `(defmethod execute :around
       (mode (command ,command) argument)
     (declare (ignore mode command argument))
     (if (electric-active-selection-p)
         (electric-paredit-wrap-selection (current-point) ,open ,close)
         (call-next-method))))

(define-electric-paredit-region-wrapper
  lem-paredit-mode:paredit-insert-paren #\( #\))
(define-electric-paredit-region-wrapper
  lem-paredit-mode:paredit-insert-bracket #\[ #\])
(define-electric-paredit-region-wrapper
  lem-paredit-mode:paredit-insert-brace #\{ #\})
(define-electric-paredit-region-wrapper
  lem-paredit-mode:paredit-insert-doublequote #\" #\")
