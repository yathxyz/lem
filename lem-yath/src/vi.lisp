;;;; Modal editing: evil -> lem-vi-mode.
;;;; Covers: vi-mode activation, SPC as leader, the `gc` comment operator
;;;; (evil-nerd-commenter), surround (evil-surround) and a 2-char snipe
;;;; (evil-snipe). Leader bindings themselves live in keybindings.lisp.

(in-package :lem-yath)

(lem-vi-mode:vi-mode)

;; SPC is the leader, exactly like the Emacs general.el setup. vi-mode
;; rewrites a leader-key press into the symbolic "Leader" key for vi keymaps,
;; so "Leader x y" chords below behave like SPC-x-y.
(setf (variable-value 'lem-vi-mode/leader:leader-key :global) "Space")

;;; --- insert-state editing --------------------------------------------------

(define-command lem-yath-delete-back-to-indentation () ()
  "Delete from point back to indentation, like Evil insert-state C-u."
  (with-point ((line-start (current-point))
               (indentation (current-point)))
    (line-start line-start)
    (line-start indentation)
    (skip-chars-forward indentation '(#\Space #\Tab))
    (let* ((point (current-point))
           (target (if (point< indentation point) indentation line-start))
           (length (- (position-at-point point) (position-at-point target))))
      (when (plusp length)
        (delete-character target length)))))

;;; --- gc: comment operator (evil-nerd-commenter) ---------------------------

(defun line-comment-string ()
  (or (variable-value 'lem/language-mode:insertion-line-comment :buffer)
      (variable-value 'lem/language-mode:line-comment :buffer)))

(defun map-region-lines (start end fn)
  "Call FN with a point at the start of every line in START..END."
  (let ((last-line (line-number-at-point end)))
    ;; A linewise region can end at column 0 of the line *after* the last
    ;; selected line; don't touch that line.
    (when (and (> last-line (line-number-at-point start))
               (zerop (point-charpos end)))
      (decf last-line))
    (with-point ((p start :left-inserting))
      (line-start p)
      (loop
        (funcall fn p)
        (unless (and (line-offset p 1)
                     (<= (line-number-at-point p) last-line))
          (return))))))

(defun toggle-comment-lines (start end)
  (let ((cmt (line-comment-string)))
    (unless cmt
      (message "No line comment defined for this mode")
      (return-from toggle-comment-lines))
    (let ((all-commented t))
      (map-region-lines start end
                        (lambda (p)
                          (let ((trimmed (string-left-trim '(#\Space #\Tab)
                                                           (line-string p))))
                            (when (and (plusp (length trimmed))
                                       (not (alexandria:starts-with-subseq cmt trimmed)))
                              (setf all-commented nil)))))
      (map-region-lines start end
                        (lambda (p)
                          (let* ((text (line-string p))
                                 (trimmed (string-left-trim '(#\Space #\Tab) text))
                                 (indent (- (length text) (length trimmed))))
                            (unless (zerop (length trimmed))
                              (character-offset p indent)
                              (cond (all-commented
                                     (delete-character p (length cmt))
                                     (when (eql (character-at p) #\Space)
                                       (delete-character p 1)))
                                    (t
                                     (insert-string p (concatenate 'string cmt " ")))))))))))

(lem-vi-mode:define-operator lem-yath-comment-operator (start end type) ("<R>")
    (:move-point nil)
  (toggle-comment-lines start end))

(define-key lem-vi-mode:*normal-keymap* "g c" 'lem-yath-comment-operator)
(define-key lem-vi-mode:*visual-keymap* "g c" 'lem-yath-comment-operator)

;;; --- surround (evil-surround) ----------------------------------------------
;;; Visual `S` wraps the selection; `y s {motion}` wraps a motion;
;;; `d s {char}` deletes the nearest pair; `c s {old}{new}` changes it.

(defparameter *surround-pairs*
  '((#\( "(" ")") (#\) "(" ")") (#\b "(" ")")
    (#\[ "[" "]") (#\] "[" "]")
    (#\{ "{" "}") (#\} "{" "}") (#\B "{" "}")
    (#\< "<" ">") (#\> "<" ">")
    (#\" "\"" "\"") (#\' "'" "'") (#\` "`" "`")))

(defun surround-delimiters (char)
  (let ((entry (assoc char *surround-pairs*)))
    (if entry
        (values (second entry) (third entry))
        (let ((s (string char)))
          (values s s)))))

(defun spaced-surround-character-p (char)
  (member char '(#\( #\[ #\{)))

(defun surround-insertion-pair (char)
  (multiple-value-bind (open close) (surround-delimiters char)
    (if (spaced-surround-character-p char)
        (values (concatenate 'string open " ")
                (concatenate 'string " " close))
        (values open close))))

(defun read-vi-character (prompt)
  "Read one character without entering Lem's prompt state."
  (message "~A" prompt)
  (let ((key (read-key)))
    (cond ((abort-key-p key)
           (error 'editor-abort))
          ((key-to-char key))
          (t
           (editor-error "Expected a character")))))

(lem-vi-mode:define-operator lem-yath-surround-operator (start end type) ("<R>")
  (:move-point nil)
  (multiple-value-bind (open close)
      (surround-insertion-pair (read-vi-character "Surround with: "))
    (with-point ((s start :right-inserting)
                 (e end :left-inserting))
      (insert-string e close)
      (insert-string s open))))

(defun find-surrounding (open close)
  "Nearest OPEN before point and CLOSE after point. Returns two points or NIL.
Deliberately naive (no balancing) -- covers the common interactive cases."
  (let ((here (current-point)))
    (with-point ((back here)
                 (fwd here))
      (when (and (search-backward back open)
                 (search-forward fwd close))
        (values (copy-point back :temporary)
                (copy-point fwd :temporary))))))

(defun remove-surrounding (start end open close trim-padding)
  "Remove OPEN and CLOSE at START and END, optionally removing inner spaces."
  (character-offset end (- (length close)))
  (delete-character end (length close))
  (when (and trim-padding (eql (character-at end -1) #\Space))
    (character-offset end -1)
    (delete-character end 1))
  (delete-character start (length open))
  (when (and trim-padding (eql (character-at start) #\Space))
    (delete-character start 1)))

(defun change-surrounding-pair (start end old-open old-close
                                new-open new-close trim-padding)
  "Replace a surrounding pair without relying on points shifted by edits."
  (character-offset end (- (length old-close)))
  (delete-character end (length old-close))
  (when (and trim-padding (eql (character-at end -1) #\Space))
    (character-offset end -1)
    (delete-character end 1))
  (insert-string end new-close)
  (delete-character start (length old-open))
  (when (and trim-padding (eql (character-at start) #\Space))
    (delete-character start 1))
  (insert-string start new-open))

(define-command lem-yath-surround-delete () ()
  "Delete the nearest surrounding pair (ds in evil-surround)."
  (let ((char (read-vi-character "Delete surround: ")))
    (multiple-value-bind (open close) (surround-delimiters char)
    (multiple-value-bind (s e) (find-surrounding open close)
      (cond ((and s e)
             (remove-surrounding s e open close
                                 (spaced-surround-character-p char)))
            (t
             (message "No surrounding ~a...~a found" open close)))))))

(define-command lem-yath-surround-change () ()
  "Change the nearest surrounding pair (cs in evil-surround)."
  (let ((old-char (read-vi-character "Change surround: ")))
    (multiple-value-bind (old-open old-close) (surround-delimiters old-char)
      (multiple-value-bind (new-open new-close)
          (surround-insertion-pair
           (read-vi-character (format nil "Replace ~a...~a with: "
                                      old-open old-close)))
      (multiple-value-bind (s e) (find-surrounding old-open old-close)
        (cond ((and s e)
               (change-surrounding-pair
                s e old-open old-close new-open new-close
                (spaced-surround-character-p old-char)))
              (t
               (message "No surrounding ~a...~a found"
                        old-open old-close))))))))

(defun call-vi-operator (command argument key)
  "Run native vi operator COMMAND with ARGUMENT after restoring KEY."
  (unread-key key)
  (call-command command argument))

(lem-vi-mode:define-motion lem-yath-line-motion (&optional (n 1)) (:universal)
  (:type :line)
  (line-offset (current-point) (1- n)))

(lem-vi-mode:define-operator lem-yath-yank-lines (start end type) ("<R>")
  (:motion lem-yath-line-motion :move-point nil)
  (lem-vi-mode/commands:vi-yank start end type))

(lem-vi-mode:define-operator lem-yath-delete-lines (start end type) ("<R>")
  (:motion lem-yath-line-motion :move-point nil)
  (let ((lem-core::*this-command*
          (get-command 'lem-vi-mode/commands:vi-delete)))
    (lem-vi-mode/commands:vi-delete start end type)))

(lem-vi-mode:define-operator lem-yath-change-lines (start end type) ("<R>")
  (:motion lem-yath-line-motion :move-point nil)
  (lem-vi-mode/commands:vi-change start end type))

(define-command lem-yath-yank-or-surround (argument) (:universal-nil)
  "Run native `y`, or evil-surround `ys` when followed by s."
  (if (lem-vi-mode/visual:visual-p)
      (call-command (if (structural-editing-p)
                        'lem-yath-structural-yank
                        'lem-vi-mode/commands:vi-yank)
                    argument)
      (let ((key (read-key)))
        (case (key-to-char key)
          (#\s
           (call-command 'lem-yath-surround-operator argument))
          (#\y
           (call-command (if (structural-editing-p)
                             'lem-yath-structural-yank-lines
                             'lem-yath-yank-lines)
                         argument))
          (otherwise
           (call-vi-operator (if (structural-editing-p)
                                 'lem-yath-structural-yank
                                 'lem-vi-mode/commands:vi-yank)
                             argument key))))))

(define-command lem-yath-delete-or-surround (argument) (:universal-nil)
  "Run native `d`, or evil-surround `ds` when followed by s."
  (if (lem-vi-mode/visual:visual-p)
      (call-command (if (structural-editing-p)
                        'lem-yath-structural-delete
                        'lem-vi-mode/commands:vi-delete)
                    argument)
      (let ((key (read-key)))
        (case (key-to-char key)
          (#\s
           (lem-yath-surround-delete))
          (#\d
           (call-command (if (structural-editing-p)
                             'lem-yath-structural-delete-lines
                             'lem-yath-delete-lines)
                         argument))
          (otherwise
           (call-vi-operator (if (structural-editing-p)
                                 'lem-yath-structural-delete
                                 'lem-vi-mode/commands:vi-delete)
                             argument key))))))

(define-command lem-yath-change-or-surround (argument) (:universal-nil)
  "Run native `c`, or evil-surround `cs` when followed by s."
  (if (lem-vi-mode/visual:visual-p)
      (call-command (if (structural-editing-p)
                        'lem-yath-structural-change
                        'lem-vi-mode/commands:vi-change)
                    argument)
      (let ((key (read-key)))
        (case (key-to-char key)
          (#\s
           (lem-yath-surround-change))
          (#\c
           (call-command (if (structural-editing-p)
                             'lem-yath-structural-change-lines
                             'lem-yath-change-lines)
                         argument))
          (otherwise
           (call-vi-operator (if (structural-editing-p)
                                 'lem-yath-structural-change
                                 'lem-vi-mode/commands:vi-change)
                             argument key))))))

(define-command lem-yath-yank-line-dispatch (argument) (:universal-nil)
  "Use Lispyville's safe y$ in structural buffers and Vim's whole-line Y elsewhere."
  (call-command (if (structural-editing-p)
                    'lem-yath-structural-yank-to-line-end
                    'lem-yath-yank-lines)
                argument))

(define-key lem-vi-mode:*visual-keymap* "S" 'lem-yath-surround-operator)
(define-key lem-vi-mode:*normal-keymap* "y" 'lem-yath-yank-or-surround)
(define-key lem-vi-mode:*normal-keymap* "Y" 'lem-yath-yank-line-dispatch)
(define-key lem-vi-mode:*normal-keymap* "d" 'lem-yath-delete-or-surround)
(define-key lem-vi-mode:*normal-keymap* "c" 'lem-yath-change-or-surround)

;;; --- snipe (evil-snipe 2.1.3) ---------------------------------------------

(define-attribute lem-yath-snipe-match-attribute
  (t :foreground :base00 :background :base05))

(define-attribute lem-yath-snipe-first-match-attribute
  (t :foreground :base00 :background :base0D))

;; The persistent record backs ; and ,.  The separate family flag emulates
;; evil-snipe's transient map: immediately after a successful search, the
;; corresponding lower/upper-case pair repeats instead of reading a new key.
(defvar *last-snipe-search* nil)
(defvar *snipe-immediate-repeat-family* nil)
(defvar *snipe-transient-buffer* nil)
(defvar *snipe-overlays* nil)

(defvar *snipe-s-transient-keymap*
  (make-keymap :description '*snipe-s-transient-keymap*))
(defvar *snipe-f-transient-keymap*
  (make-keymap :description '*snipe-f-transient-keymap*))
(defvar *snipe-t-transient-keymap*
  (make-keymap :description '*snipe-t-transient-keymap*))
(defvar *snipe-x-transient-keymap*
  (make-keymap :description '*snipe-x-transient-keymap*))

(define-minor-mode lem-yath-snipe-s-transient-mode
    (:name "snipe-s-repeat"
     :keymap *snipe-s-transient-keymap*
     :hide-from-modeline t))
(define-minor-mode lem-yath-snipe-f-transient-mode
    (:name "snipe-f-repeat"
     :keymap *snipe-f-transient-keymap*
     :hide-from-modeline t))
(define-minor-mode lem-yath-snipe-t-transient-mode
    (:name "snipe-t-repeat"
     :keymap *snipe-t-transient-keymap*
     :hide-from-modeline t))
(define-minor-mode lem-yath-snipe-x-transient-mode
    (:name "snipe-x-repeat"
     :keymap *snipe-x-transient-keymap*
     :hide-from-modeline t))

(defparameter *snipe-transient-modes*
  '(lem-yath-snipe-s-transient-mode
    lem-yath-snipe-f-transient-mode
    lem-yath-snipe-t-transient-mode
    lem-yath-snipe-x-transient-mode))

(defun disarm-snipe-transient ()
  ;; The command that switches buffers finishes in the destination buffer.
  ;; Disable the mode in both that buffer and the one where it was armed, or a
  ;; stale transient map would unexpectedly revive when returning later.
  (dolist (buffer (remove-duplicates
                   (remove nil (list *snipe-transient-buffer*
                                     (current-buffer)))))
    (when (member buffer (buffer-list))
      (with-current-buffer buffer
        (dolist (mode *snipe-transient-modes*)
          (when (mode-active-p buffer mode)
            (disable-minor-mode mode))))))
  (setf *snipe-immediate-repeat-family* nil
        *snipe-transient-buffer* nil))

(defun arm-snipe-transient (family)
  (disarm-snipe-transient)
  (setf *snipe-immediate-repeat-family* family
        *snipe-transient-buffer* (current-buffer))
  (enable-minor-mode
   (ecase family
     (:s 'lem-yath-snipe-s-transient-mode)
     (:f 'lem-yath-snipe-f-transient-mode)
     (:t 'lem-yath-snipe-t-transient-mode)
     (:x 'lem-yath-snipe-x-transient-mode))))

(defun clear-snipe-overlays ()
  (mapc #'delete-overlay *snipe-overlays*)
  (setf *snipe-overlays* nil))

(defun reverse-snipe-direction (direction)
  (ecase direction
    (:forward :backward)
    (:backward :forward)))

(defun visible-snipe-bounds ()
  "Return temporary points bounding the exact visible buffer rows.
The end point is the beginning of the first non-visible virtual line, or the
buffer end.  This keeps wrapped lines and the modeline out of the search."
  (let* ((window (current-window))
         (top (copy-point (window-view-point window) :temporary))
         (bottom (copy-point top :temporary))
         (body-height (- (window-height window)
                         (if (window-use-modeline-p window) 1 0))))
    (if (plusp body-height)
        (unless (move-to-next-virtual-line bottom body-height window)
          (buffer-end bottom))
        (move-point bottom top))
    (values top bottom)))

(defun directional-snipe-bounds (direction)
  "Return visible bounds restricted from point in DIRECTION."
  (multiple-value-bind (top bottom) (visible-snipe-bounds)
    (ecase direction
      (:forward
       (with-point ((start (current-point)))
         (unless (character-offset start 1)
           (move-point start bottom))
         (values (copy-point start :temporary) bottom)))
      (:backward
       (values top (copy-point (current-point) :temporary))))))

(defun movement-snipe-bounds (direction inclusive)
  "Return bounds for the next motion target.
Exclusive t/T-style searches skip the adjacent target so repeats cannot get
stuck on the character that the cursor is already beside."
  (multiple-value-bind (top bottom) (visible-snipe-bounds)
    (ecase direction
      (:forward
       (with-point ((start (current-point)))
         (unless (character-offset start (if inclusive 1 2))
           (move-point start bottom))
         (values (copy-point start :temporary) bottom)))
      (:backward
       (with-point ((end (current-point)))
         (unless (or inclusive (character-offset end -1))
           (move-point end top))
         (values top (copy-point end :temporary)))))))

(defun snipe-whitespace-character-p (character)
  (member character '(#\Space #\Tab)))

(defun terminal-whitespace-search-p (target search-start)
  "Whether evil-snipe's leading-whitespace adjustment applies here."
  (and (plusp (length target))
       (snipe-whitespace-character-p (char target 0))
       (snipe-whitespace-character-p (character-at search-start))))

(defun terminal-whitespace-match-p (match target)
  "Whether MATCH is the last target-width window in a whitespace run."
  (with-point ((after match))
    (character-offset after (length target))
    (let ((character (character-at after)))
      (and character (not (snipe-whitespace-character-p character))))))

(defun snipe-forward-limit (end)
  "Avoid Lem's bounded-search rejection for matches ending at buffer end."
  (unless (end-buffer-p end) end))

(defun snipe-forward-match-points-between
    (target start end &key terminal-whitespace)
  "Return non-overlapping, case-sensitive TARGET starts in START..END.
When TERMINAL-WHITESPACE is true, reproduce evil-snipe's adjustment that
selects only the final target-width window before a non-whitespace character."
  (let (;; Lem's historical variable is inverted: true selects CHAR= (the
        ;; case-sensitive comparator), while NIL selects CHAR-EQUAL.
        (*case-fold-search* t)
        (limit (snipe-forward-limit end)))
    (with-point ((scan start))
      (loop :with matches := '()
            :while (and (point< scan end)
                        (search-forward scan target limit))
            :for match := (copy-point scan :temporary)
            :do (character-offset match (- (length target)))
                (if (and terminal-whitespace
                         (not (terminal-whitespace-match-p match target)))
                    ;; A literal search consumes the candidate.  Move only one
                    ;; character so an overlapping terminal window remains
                    ;; discoverable, just as upstream's TARGET[^ \t] regexp is.
                    (progn
                      (move-point scan match)
                      (character-offset scan 1))
                    (push match matches))
            :finally (return (nreverse matches))))))

(defun two-whitespace-characters-at-p (point)
  (and (snipe-whitespace-character-p (character-at point))
       (snipe-whitespace-character-p (character-at point 1))))

(defun snipe-highlight-points-between (target start end)
  "Return match points using evil-snipe's incremental-highlight scan."
  (let ((*case-fold-search* t)
        (limit (snipe-forward-limit end)))
    (with-point ((scan start))
      (loop :with matches := '()
            :while (and (point< scan end)
                        (search-forward scan target limit))
            :for match := (copy-point scan :temporary)
            :do (character-offset match (- (length target)))
                (if (two-whitespace-characters-at-p scan)
                    (progn
                      (skip-chars-forward scan '(#\Space #\Tab))
                      (character-offset scan (- (length target))))
                    (push match matches))
            :finally (return (nreverse matches))))))

(defun snipe-highlight-points (target direction &key whole-visible)
  "Return scoped TARGET points in display order for highlighting."
  (if whole-visible
      (multiple-value-bind (top bottom) (visible-snipe-bounds)
        (snipe-highlight-points-between target top bottom))
      (multiple-value-bind (start end) (directional-snipe-bounds direction)
        (snipe-highlight-points-between target start end))))

(defun make-snipe-highlight (point length attribute)
  (with-point ((start point)
               (end point))
    (character-offset end length)
    (push (make-overlay start end attribute) *snipe-overlays*)))

(defun install-snipe-highlights (target direction &key whole-visible selected)
  "Highlight scoped TARGET matches, distinguishing SELECTED when supplied.
The selected match is installed separately because directional scope begins
after the new cursor position.  Splitting its characters also ensures the
cursor cell does not mask the remainder of a multi-character first match."
  (clear-snipe-overlays)
  (dolist (point (snipe-highlight-points target direction
                                         :whole-visible whole-visible))
    (unless (and selected (point= point selected))
      (make-snipe-highlight point (length target)
                            'lem-yath-snipe-match-attribute)))
  (when selected
    (dotimes (offset (length target))
      (with-point ((character selected))
        (character-offset character offset)
        (make-snipe-highlight character 1
                              'lem-yath-snipe-first-match-attribute)))))

(defun read-snipe-target (length direction)
  "Read up to LENGTH characters with evil-snipe-style prefix highlighting.
Escape/C-g abort, Backspace aborts an incomplete two-character search, and
Return either repeats the prior search or accepts the prefix already entered."
  (let ((characters '()))
    (unwind-protect
        (loop
          (show-message
           (format nil "~D>~A"
                   (- length (length characters))
                   (coerce (reverse characters) 'string))
           :timeout nil)
          (clear-snipe-overlays)
          (when characters
            (install-snipe-highlights (coerce (reverse characters) 'string)
                                      direction))
          ;; read-key does not redraw before blocking, so the explicit redraw is
          ;; what makes the incremental candidates observable.
          (redraw-display)
          (let ((key (read-key)))
            (cond
              ((or (abort-key-p key)
                   (match-key key :ctrl t :sym "g")
                   (match-key key :sym "Escape"))
               (error 'editor-abort))
              ((match-key key :sym "Return")
               (return (if characters
                           (coerce (reverse characters) 'string)
                           :repeat)))
              ((or (match-key key :sym "Backspace")
                   (match-key key :sym "Delete"))
               (if (<= (length characters) 1)
                   (error 'editor-abort)
                   (pop characters)))
              ((key-to-char key)
               (push (key-to-char key) characters)
               (when (= (length characters) length)
                 (return (coerce (reverse characters) 'string))))
              (t
               (editor-error "Expected a snipe character")))))
      (clear-snipe-overlays)
      (clear-message))))

(defun nth-snipe-point (target direction count inclusive)
  (multiple-value-bind (start end) (movement-snipe-bounds direction inclusive)
    (let ((terminal-whitespace
            (terminal-whitespace-search-p
             target (if (eq direction :forward) start end))))
      (ecase direction
        (:forward
         (nth (1- count)
              (snipe-forward-match-points-between
               target start end :terminal-whitespace terminal-whitespace)))
        (:backward
         (let ((*case-fold-search* t))
           (with-point ((scan end))
             (loop :repeat count
                   :for found := nil
                   :do (loop
                         (unless (search-backward scan target start)
                           (return))
                         (let ((candidate (copy-point scan :temporary)))
                           (when (or (not terminal-whitespace)
                                     (terminal-whitespace-match-p
                                      candidate target))
                             (setf found candidate)
                             (return))))
                   :unless found :do (return nil)
                   :finally (return found)))))))))

(defun snipe-destination-point (match target direction inclusive)
  "Return the cursor/motion endpoint for a match.
Forward inclusive operators and visual selections must include the complete
multi-character target.  Exclusive motions stop outside the target."
  (let ((operator-p (lem-vi-mode/commands/utils:operator-pending-mode-p))
        (visual-p (lem-vi-mode/visual:visual-p))
        (length (length target))
        (destination (copy-point match :temporary)))
    (character-offset
     destination
     (ecase direction
       (:forward
        (if inclusive
            (if (or operator-p visual-p) (1- length) 0)
            (if operator-p 0 -1)))
       (:backward
        (if inclusive 0 length))))
    destination))

(defun effective-snipe-motion-type (direction inclusive)
  ;; A backward exclusive operator must include its origin while leaving the
  ;; target intact.  Lem expresses that range with an inclusive dynamic type.
  (if (and (lem-vi-mode/commands/utils:operator-pending-mode-p)
           (eq direction :backward)
           (not inclusive))
      :inclusive
      (if inclusive :inclusive :exclusive)))

(defun perform-snipe-search
    (search repeat-count reverse-p whole-visible &optional repeat-p)
  "Perform SEARCH and return its motion type.
REPEAT-COUNT multiplies the original count.  REVERSE-P inverts the stored
direction without changing the persistent search record."
  (let* ((target (getf search :target))
         (stored-direction (getf search :direction))
         (direction (if reverse-p
                        (reverse-snipe-direction stored-direction)
                        stored-direction))
         (inclusive (getf search :inclusive))
         (count (* (getf search :count) (max 1 (or repeat-count 1))))
         (match (nth-snipe-point target direction count inclusive))
         (operator-p (lem-vi-mode/commands/utils:operator-pending-mode-p)))
    (unless match
      (if (and repeat-p (not operator-p))
          (arm-snipe-transient (getf search :family))
          (disarm-snipe-transient))
      (editor-error "Can't find ~S" target))
    (move-point (current-point)
                (snipe-destination-point match target direction inclusive))
    (install-snipe-highlights target direction
                              :whole-visible whole-visible
                              :selected (unless (or operator-p
                                                    (lem-vi-mode/visual:visual-p))
                                          match))
    (unless operator-p
      (arm-snipe-transient (getf search :family)))
    (redraw-display)
    (effective-snipe-motion-type direction inclusive)))

(defun make-snipe-motion-range (origin type)
  (lem-vi-mode/core:make-range
   (copy-point origin :temporary)
   (copy-point (current-point) :temporary)
   type))

(defun repeat-last-snipe (count reverse-p)
  (unless *last-snipe-search*
    (editor-error "Nothing to repeat"))
  (perform-snipe-search *last-snipe-search* count reverse-p t t))

(defun dispatch-snipe (count direction inclusive match-count family)
  "Start a configured evil-snipe motion or repeat via an empty Return target.
The third return value is true when the stored search supplied the dynamic
motion type (Return).  Immediate lower/upper repeats use transient minor-mode
keymaps and therefore execute the non-jumping repeat motions directly."
  (let ((count (max 1 (or count 1))))
    (disarm-snipe-transient)
    (let ((target (read-snipe-target match-count direction)))
      (if (eq target :repeat)
          (values t
                  (repeat-last-snipe count (eq direction :backward))
                  t)
          (let ((search (list :target target
                              :direction direction
                              :inclusive inclusive
                              :count count
                              :family family)))
            ;; evil-snipe remembers even a search that subsequently has no
            ;; match, so ;/, can retry it from another point.
            (setf *last-snipe-search* search)
            (let ((type (perform-snipe-search search 1 nil nil)))
              (values t type
                      (not (eq type (if inclusive
                                        :inclusive
                                        :exclusive))))))))))

(defmacro define-snipe-motion (name direction inclusive match-count family)
  `(lem-vi-mode:define-motion ,name (&optional (n 1)) (:universal)
       (:type ,(if inclusive :inclusive :exclusive) :jump t)
     (with-point ((origin (current-point)))
       (multiple-value-bind (success type dynamic-type-p)
           (dispatch-snipe n ,direction ,inclusive ,match-count ,family)
         (when (and success dynamic-type-p)
           (make-snipe-motion-range origin type))))))

(define-snipe-motion lem-yath-snipe-forward :forward t 2 :s)
(define-snipe-motion lem-yath-snipe-backward :backward t 2 :s)
(define-snipe-motion lem-yath-snipe-find-forward :forward t 1 :f)
(define-snipe-motion lem-yath-snipe-find-backward :backward t 1 :f)
(define-snipe-motion lem-yath-snipe-till-forward :forward nil 1 :t)
(define-snipe-motion lem-yath-snipe-till-backward :backward nil 1 :t)

;; Operator-only two-character aliases retain evil-snipe's inclusive z/Z and
;; exclusive x/X behavior, but never arm the immediate normal-state repeat map.
(define-snipe-motion lem-yath-snipe-operator-forward :forward t 2 :s)
(define-snipe-motion lem-yath-snipe-operator-backward :backward t 2 :s)
(define-snipe-motion lem-yath-snipe-operator-forward-exclusive :forward nil 2 :x)
(define-snipe-motion lem-yath-snipe-operator-backward-exclusive :backward nil 2 :x)

(lem-vi-mode:define-motion lem-yath-snipe-repeat (&optional (n 1)) (:universal)
    (:type :exclusive)
  (with-point ((origin (current-point)))
    (make-snipe-motion-range origin (repeat-last-snipe n nil))))

(lem-vi-mode:define-motion lem-yath-snipe-repeat-backward (&optional (n 1)) (:universal)
    (:type :exclusive)
  (with-point ((origin (current-point)))
    (make-snipe-motion-range origin (repeat-last-snipe n t))))

(define-key *snipe-s-transient-keymap* "s" 'lem-yath-snipe-repeat)
(define-key *snipe-s-transient-keymap* "S" 'lem-yath-snipe-repeat-backward)
(define-key *snipe-f-transient-keymap* "f" 'lem-yath-snipe-repeat)
(define-key *snipe-f-transient-keymap* "F" 'lem-yath-snipe-repeat-backward)
(define-key *snipe-t-transient-keymap* "t" 'lem-yath-snipe-repeat)
(define-key *snipe-t-transient-keymap* "T" 'lem-yath-snipe-repeat-backward)
(define-key *snipe-x-transient-keymap* "x" 'lem-yath-snipe-repeat)
(define-key *snipe-x-transient-keymap* "X" 'lem-yath-snipe-repeat-backward)

(defparameter *snipe-transient-preserving-command-names*
  '(lem-yath-snipe-forward
    lem-yath-snipe-backward
    lem-yath-snipe-find-forward
    lem-yath-snipe-find-backward
    lem-yath-snipe-till-forward
    lem-yath-snipe-till-backward
    lem-yath-snipe-repeat
    lem-yath-snipe-repeat-backward))

(defun snipe-transient-preserving-command-p ()
  (and (this-command)
       (member (command-name (this-command))
               *snipe-transient-preserving-command-names*)))

(defun snipe-pre-command-cleanup ()
  (when *snipe-overlays*
    (clear-snipe-overlays)
    (redraw-display))
  ;; Disarm before operators read their nested motion.  Waiting until the
  ;; outer command's post hook would let an old f/t/x transient map intercept
  ;; `d f`, `d t`, or `d x`.
  (unless (snipe-transient-preserving-command-p)
    (disarm-snipe-transient)))

;; Keep source reloads idempotent, including removal of the old target-clearing
;; and post-command hooks used by earlier implementations.
(clear-snipe-overlays)
(disarm-snipe-transient)
(remove-hook *pre-command-hook* 'snipe-pre-command-cleanup)
(remove-hook *post-command-hook* 'snipe-post-command-cleanup)
(remove-hook *post-command-hook* 'clear-stale-snipe-repeat)
(add-hook *pre-command-hook* 'snipe-pre-command-cleanup)

(define-key lem-vi-mode:*normal-keymap* "s" 'lem-yath-snipe-forward)
(define-key lem-vi-mode:*normal-keymap* "S" 'lem-yath-snipe-backward)
(define-key lem-vi-mode:*motion-keymap* "f" 'lem-yath-snipe-find-forward)
(define-key lem-vi-mode:*motion-keymap* "F" 'lem-yath-snipe-find-backward)
(define-key lem-vi-mode:*motion-keymap* "t" 'lem-yath-snipe-till-forward)
(define-key lem-vi-mode:*motion-keymap* "T" 'lem-yath-snipe-till-backward)
(define-key lem-vi-mode:*operator-keymap* "z" 'lem-yath-snipe-operator-forward)
(define-key lem-vi-mode:*operator-keymap* "Z" 'lem-yath-snipe-operator-backward)
(define-key lem-vi-mode:*operator-keymap* "x" 'lem-yath-snipe-operator-forward-exclusive)
(define-key lem-vi-mode:*operator-keymap* "X" 'lem-yath-snipe-operator-backward-exclusive)
(define-key lem-vi-mode:*motion-keymap* ";" 'lem-yath-snipe-repeat)
(define-key lem-vi-mode:*motion-keymap* "," 'lem-yath-snipe-repeat-backward)

;;; --- incremental region expansion (expreg) ---------------------------------

(defparameter *expand-region-pairs*
  '(("(" ")") ("[" "]") ("{" "}") ("<" ">")
    ("\"" "\"") ("'" "'") ("`" "`")))

(defun enclosing-region-candidate (start end)
  "Return the smallest delimiter pair strictly containing START..END."
  (let ((best nil)
        (best-size nil))
    (dolist (pair *expand-region-pairs*)
      (destructuring-bind (open close) pair
        (with-point ((back start)
                     (forward end))
          (when (and (search-backward back open)
                     (search-forward forward close)
                     (point< back start)
                     (point< end forward))
            (let ((size (- (position-at-point forward)
                           (position-at-point back))))
              (when (or (null best-size) (< size best-size))
                (setf best-size size
                      best (list (copy-point back :temporary)
                                 (copy-point forward :temporary)))))))))
    best))

(defun expand-region-to-lines (start end)
  (with-point ((line-start start)
               (line-end end))
    (line-start line-start)
    (when (and (zerop (point-charpos line-end))
               (point< start line-end))
      (line-offset line-end -1))
    (line-end line-end)
    (if (and (point= start line-start) (point= end line-end))
        nil
        (list (copy-point line-start :temporary)
              (copy-point line-end :temporary)))))

(define-command lem-yath-expand-region () ()
  "Expand the visual region through word, delimiters, line, and paragraph."
  (if (not (lem-vi-mode/visual:visual-p))
      (progn
        (lem-vi-mode/visual:vi-visual-char)
        (call-command 'lem-vi-mode/commands:vi-inner-word 1))
      (destructuring-bind (start end) (lem-vi-mode/visual:visual-range)
        (alexandria:if-let ((range (enclosing-region-candidate start end)))
          (setf (lem-vi-mode/visual:visual-range) range)
          (alexandria:if-let ((range (expand-region-to-lines start end)))
            (setf (lem-vi-mode/visual:visual-range) range)
            (call-command 'lem-vi-mode/commands:vi-a-paragraph 1))))))
