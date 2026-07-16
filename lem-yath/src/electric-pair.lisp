;;;; Global electric-pair and delete-selection behavior.
;;;;
;;;; The Emacs configuration enables `electric-pair-mode' and
;;;; `delete-selection-mode'.  Openers wrap a non-Vi active region instead of
;;;; deleting it; ordinary self insertion replaces that region.  Vi visual
;;;; state keeps its modal key grammar, and Paredit remains authoritative in
;;;; Lisp-family buffers.

(in-package :lem-yath)

(defparameter *electric-text-pairs*
  (list (cons (code-char #x2018) (code-char #x2019))
        (cons (code-char #x201c) (code-char #x201d)))
  "Electric Pair's language-independent asymmetric quote pairs.")

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
        character)
      (cdr (assoc character *electric-text-pairs* :test #'char=))))

(defun electric-text-closing-character-p (character)
  (and character
       (rassoc character *electric-text-pairs* :test #'char=)))

(defun electric-closing-character-p (character)
  (or (syntax-closed-paren-char-p character)
      (electric-text-closing-character-p character)
      (alexandria:when-let ((close (electric-opening-close character)))
        (char= character close))))

(defun electric-special-character-p (character)
  (or (electric-opening-close character)
      (electric-closing-character-p character)))

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

(defun electric-state-container-start (state)
  "Return STATE's string/comment start, or NIL in ordinary code."
  (and (pps-state-string-or-comment-p state)
       (pps-state-token-start-point state)))

(defun electric-opening-matches-close-p (open close)
  "Whether syntax opener OPEN is paired with CLOSE."
  (alexandria:when-let ((pair (syntax-open-paren-char-p open)))
    (eql (cdr pair) close)))

(defun electric-container-open-stack (container-start point)
  "Return unmatched openers before POINT in its text container."
  (let (opens)
    (with-point ((cursor container-start))
      (loop :while (point< cursor point)
            :for current = (character-at cursor)
            :unless (syntax-escape-point-p cursor 0)
              :do (cond
                    ((syntax-open-paren-char-p current)
                     (push current opens))
                    ((and (syntax-closed-paren-char-p current)
                          opens
                          (electric-opening-matches-close-p
                           (car opens) current))
                     (pop opens)))
            :do (character-offset cursor 1)))
    opens))

(defun electric-unmatched-close-forward-p (point character)
  "Whether the first forward mismatch from POINT is CHARACTER.

This is Electric Pair's preserve-balance scan.  Balanced intervening forms do
not hide a later unmatched closer, while a different mismatched closer stops
the search.  Delimiters in strings and comments are ignored from code; inside
one of those containers they are parsed independently until its boundary."
  (let* ((state (syntax-ppss point))
         (container-start (electric-state-container-start state))
         (opens
           (if container-start
               (electric-container-open-stack container-start point)
               (copy-list (pps-state-paren-stack state)))))
    (with-point ((cursor point)
                 (end (buffer-end-point (point-buffer point))))
      (loop :while (point< cursor end)
            :for cursor-state = (syntax-ppss cursor)
            :for cursor-container =
              (electric-state-container-start cursor-state)
            :for same-container-p =
              (and container-start cursor-container
                   (point= container-start cursor-container))
            :do
               (cond
                 ;; Text containers have their own delimiter balance.  Once
                 ;; their closing boundary is crossed, no later code closer
                 ;; can balance an opener typed inside them.
                 ((and container-start (not same-container-p))
                  (return nil))
                 ;; From code, strings and comments are opaque.  Scanning
                 ;; resumes when their original syntax domain ends.
                 ((and (null container-start) cursor-container))
                 (t
                  (let ((current (character-at cursor)))
                    (cond
                      ((syntax-open-paren-char-p current)
                       (push current opens))
                      ((syntax-closed-paren-char-p current)
                       (if (and opens
                                (electric-opening-matches-close-p
                                 (car opens) current))
                           (pop opens)
                           (return (eql current character))))))))
               (character-offset cursor 1)
            :finally (return nil)))))

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
            (electric-unmatched-close-forward-p point close))
       (insert-character point character))
      (close
       (insert-character point character)
       (insert-character point close)
       (character-offset point -1))
      ((and (electric-closing-character-p character)
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
                       (electric-unmatched-close-forward-p
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

(defun electric-backspace-key-p ()
  "Whether the current command came from one physical Backspace key."
  (let ((keys (last-read-key-sequence)))
    (and (listp keys)
         (null (cdr keys))
         (match-key (car keys) :sym "Backspace"))))

(defun electric-vi-replace-state-p ()
  (and (typep (current-global-mode) 'lem-vi-mode:vi-mode)
       (typep (lem-vi-mode/core:current-state)
              'lem-vi-mode/states:replace-state)))

(defun electric-paredit-printable-command-p (command)
  "Whether COMMAND is a printable character command owned by Paredit."
  (or (typep command 'lem-paredit-mode:paredit-insert-paren)
      (typep command 'lem-paredit-mode:paredit-insert-bracket)
      (typep command 'lem-paredit-mode:paredit-insert-brace)
      (typep command 'lem-paredit-mode:paredit-insert-doublequote)
      (typep command 'lem-paredit-mode:paredit-insert-vertical-line)
      (typep command 'lem-paredit-mode:paredit-close-parenthesis)
      (typep command 'lem-paredit-mode:paredit-close-bracket)
      (typep command 'lem-paredit-mode:paredit-close-brace)))

(defun electric-paredit-printable-character (command)
  "Return the physical character whose Paredit binding resolved to COMMAND."
  (let ((character (insertion-key-p (last-read-key-sequence))))
    (and (mode-active-p (current-buffer) 'lem-paredit-mode:paredit-mode)
         character
         (electric-paredit-printable-command-p command)
         (eq (command-name command) (electric-paredit-command character))
         character)))

(defun electric-paredit-backspace-command-p (command)
  (and (mode-active-p (current-buffer) 'lem-paredit-mode:paredit-mode)
       (electric-backspace-key-p)
       (typep command 'lem-paredit-mode:paredit-backward-delete)))

(defun electric-execute-vi-replace-character (character argument)
  "Insert CHARACTER literally after Vi's replace pre-command bookkeeping."
  ;; Configured Evil treats even an unmatched Lisp closer as raw replacement.
  ;; Lem's SELF-INSERT execute advice would reject that closer after Vi had
  ;; already removed the overwritten character.  Use the insertion primitive:
  ;; its core before/after hooks still run, while structural policy stays out.
  (lem-core/commands/edit:process-input-character character (or argument 1)))

;; Paredit's local printable bindings otherwise hide SELF-INSERT from Vi's
;; replace pre-command hook.  Present those bindings as SELF-INSERT while that
;; hook records/removes the overwritten character; the matching execute advice
;; below then performs ordinary one-character insertion instead of pairing.
(defmethod lem-vi-mode/core:pre-command-hook :around
    ((state lem-vi-mode/states:replace-state))
  (cond
    ((electric-paredit-printable-character (this-command))
     (let ((lem-core::*this-command*
             (lem/common/command:ensure-command
              'lem-core/commands/edit:self-insert)))
       (call-next-method)))
    ((electric-paredit-backspace-command-p (this-command))
     (let ((lem-core::*this-command*
             (lem/common/command:ensure-command
              'lem-core/commands/edit:delete-previous-char)))
       (call-next-method)))
    (t
     (call-next-method))))

(defun electric-execute-paredit-command (command)
  (execute
   (lem-core::get-active-modes-class-instance (current-buffer))
   (lem/common/command:ensure-command command)
   nil))

(defun electric-prompt-completion-p ()
  (alexandria:when-let ((prompt
                         (lem/prompt-window:current-prompt-window)))
    (eq (current-buffer) (window-buffer prompt))))

(defun electric-pair-deletion-context-p ()
  "Whether electric Backspace is active in the current editing state."
  (or (electric-prompt-completion-p)
      (not (typep (current-global-mode) 'lem-vi-mode:vi-mode))
      (let ((state (lem-vi-mode/core:current-state)))
        (and (typep state 'lem-vi-mode/states:insert)
             (not (typep state 'lem-vi-mode/states:replace-state))))))

(defun electric-adjacent-pair-p (&optional (point (current-point)))
  "Whether POINT is immediately between a recognized electric pair."
  (let ((open (character-at point -1))
        (close (character-at point)))
    (and open
         close
         (alexandria:when-let ((expected (electric-opening-close open)))
           (char= expected close)))))

(defun electric-pair-selection-p
    (&optional (point (current-point)))
  "Whether POINT's mark is within one character of its adjacent pair."
  (let ((mark (cursor-mark point)))
    (and (mark-active-p mark)
         (mark-point mark)
         (electric-adjacent-pair-p point)
         (<= (count-characters (cursor-region-beginning point)
                               (cursor-region-end point))
             1))))

(defun electric-delete-adjacent-pair (point count argument)
  "Delete ABS(COUNT) characters on each side of POINT as one safe command.

The immediate characters must form an electric pair.  Preflight the complete
range so bounds and read-only properties cannot fail after half the pair has
changed.  COUNT's sign controls which half enters the kill ring, matching
Emacs.  Record both halves separately so undo restores point between them."
  (let* ((magnitude (abs count))
         (mark (cursor-mark point))
         (restore-mark-p (mark-active-p mark)))
    ;; Buffer modification normally consumes an active Lem mark.  Electric
    ;; Pair instead leaves a selected delimiter as a zero-width active mark.
    (when restore-mark-p
      (setf (mark-active-p mark) nil))
    (unwind-protect
         (with-point ((start point)
                      (end point))
           (unless (and (character-offset start (- magnitude))
                        (character-offset end magnitude))
             (editor-error "Not enough characters around electric pair"))
           (unless lem/buffer/internal:*inhibit-read-only*
             (lem/buffer/internal::check-read-only-buffer
              (point-buffer point))
             (lem/buffer/internal::check-read-only-at-point
              start (* 2 magnitude)))
           (if (plusp count)
               (progn
                 ;; The core Backspace half records the backward text.
                 (delete-character point count)
                 (lem-core/commands/edit::delete-previous-char-1 argument))
               (progn
                 ;; Seed retained undo at the original cursor before deleting
                 ;; backward, then record Emacs's forward half in the kill ring.
                 (lem-core/commands/edit:delete-next-char magnitude)
                 (delete-character point (- magnitude)))))
      (when restore-mark-p
        (setf (mark-active-p mark) t)))))

(defun electric-delete-previous-at-point (argument)
  "Run Backspace at the current cursor with electric and Paredit precedence."
  (let* ((point (current-point))
         (mark (cursor-mark point))
         (count (or argument 1)))
    (cond
      ;; Preserve ordinary delete-selection behavior, except for the useful
      ;; Emacs cases where the mark is between or selects one side of the pair.
      ((and (mark-active-p mark)
            (not (electric-pair-selection-p point)))
       (lem-core/commands/edit::delete-cursor-region point))
      ((and (not (zerop count))
            (electric-adjacent-pair-p point))
       (electric-delete-adjacent-pair point count argument))
      ;; Lem's Paredit is the Lispy/Lispyville substitute.  It remains
      ;; authoritative whenever the global adjacent-pair rule did not match.
      ((and (plusp count) (structural-editing-p))
       (lem-paredit-mode:paredit-backward-delete count))
      (t
       (lem-core/commands/edit::delete-previous-char-1 argument)))))

(defun electric-delete-previous-cursors (argument)
  "Apply electric Backspace to every cursor and retain live completion."
  (let ((completion-context lem/completion-mode::*completion-context*))
    (do-each-cursors ()
      (electric-delete-previous-at-point argument))
    ;; Paredit's symbolic Backspace remap can leave the stock command in
    ;; charge even while completion-mode is active.  Refresh that path too.
    (when (and completion-context
               (eq completion-context
                   lem/completion-mode::*completion-context*))
      (lem/completion-mode:completion-refresh))))

;; Keep the stock command identity: Vi replace history, snippets, completion,
;; and automatic-completion lifecycle tracking all depend on it.  The mode
;; specializer makes this method more specific than Lem's core (MODE T) method.
(defmethod execute :around
    ((mode lem-core::global-mode)
     (command lem-core/commands/edit:delete-previous-char)
     argument)
  (declare (ignore mode command))
  (if (and (electric-backspace-key-p)
           (electric-pair-deletion-context-p))
      (electric-delete-previous-cursors argument)
      (call-next-method)))

;; Depending on the active keymap composition, physical Backspace can resolve
;; directly to Paredit instead of the stock command.  The global adjacent-pair
;; rule still wins; all nonmatching structural deletion remains upstream.
(defmethod execute :around
    ((mode lem-core::global-mode)
     (command lem-paredit-mode:paredit-backward-delete)
     argument)
  (cond
    ((and (electric-vi-replace-state-p)
          (electric-paredit-backspace-command-p command))
     (execute mode
              (lem/common/command:ensure-command
               'lem-core/commands/edit:delete-previous-char)
              argument))
    ((and (electric-paredit-backspace-command-p command)
          (electric-pair-deletion-context-p))
     (electric-delete-previous-cursors argument))
    (t
     (call-next-method))))

;; Completion invokes DELETE-PREVIOUS-CHAR as a function, bypassing the core
;; command method above.  Apply the same behavior, then refresh exactly once.
(defmethod execute :around
    ((mode lem-core::global-mode)
     (command lem/completion-mode::completion-delete-previous-char)
     argument)
  (declare (ignore mode command))
  (if (and (electric-backspace-key-p)
           (electric-pair-deletion-context-p))
      (progn
        (electric-delete-previous-at-point argument)
        (lem/completion-mode:completion-refresh))
      (call-next-method)))

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

;; Paredit's printable commands intentionally outrank the global self-insert
;; layer.  Openers add the missing active-region wrapping case; outside Vi
;; Replace, every ordinary Lisp insertion still delegates upstream unchanged.
(defmacro define-electric-paredit-region-wrapper (command open close)
  `(defmethod execute :around
       (mode (command ,command) argument)
     (declare (ignore mode))
     (let ((replace-character
             (and (electric-vi-replace-state-p)
                  (electric-paredit-printable-character command))))
       (cond
         (replace-character
          (electric-execute-vi-replace-character replace-character argument))
         ((electric-active-selection-p)
          (electric-paredit-wrap-selection (current-point) ,open ,close))
         (t
          (call-next-method))))))

(define-electric-paredit-region-wrapper
  lem-paredit-mode:paredit-insert-paren #\( #\))
(define-electric-paredit-region-wrapper
  lem-paredit-mode:paredit-insert-bracket #\[ #\])
(define-electric-paredit-region-wrapper
  lem-paredit-mode:paredit-insert-brace #\{ #\})
(define-electric-paredit-region-wrapper
  lem-paredit-mode:paredit-insert-doublequote #\" #\")

(defmacro define-electric-paredit-replace-literal (command)
  `(defmethod execute :around
       (mode (command ,command) argument)
     (declare (ignore mode))
     (let ((replace-character
             (and (electric-vi-replace-state-p)
                  (electric-paredit-printable-character command))))
       (if replace-character
           (electric-execute-vi-replace-character replace-character argument)
           (call-next-method)))))

(define-electric-paredit-replace-literal
  lem-paredit-mode:paredit-insert-vertical-line)
(define-electric-paredit-replace-literal
  lem-paredit-mode:paredit-close-parenthesis)
(define-electric-paredit-replace-literal
  lem-paredit-mode:paredit-close-bracket)
(define-electric-paredit-replace-literal
  lem-paredit-mode:paredit-close-brace)
