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
      (call-command 'lem-vi-mode/commands:vi-yank argument)
      (let ((key (read-key)))
        (case (key-to-char key)
          (#\s
           (call-command 'lem-yath-surround-operator argument))
          (#\y
           (call-command 'lem-yath-yank-lines argument))
          (otherwise
           (call-vi-operator 'lem-vi-mode/commands:vi-yank argument key))))))

(define-command lem-yath-delete-or-surround (argument) (:universal-nil)
  "Run native `d`, or evil-surround `ds` when followed by s."
  (if (lem-vi-mode/visual:visual-p)
      (call-command 'lem-vi-mode/commands:vi-delete argument)
      (let ((key (read-key)))
        (case (key-to-char key)
          (#\s
           (lem-yath-surround-delete))
          (#\d
           (call-command 'lem-yath-delete-lines argument))
          (otherwise
           (call-vi-operator 'lem-vi-mode/commands:vi-delete argument key))))))

(define-command lem-yath-change-or-surround (argument) (:universal-nil)
  "Run native `c`, or evil-surround `cs` when followed by s."
  (if (lem-vi-mode/visual:visual-p)
      (call-command 'lem-vi-mode/commands:vi-change argument)
      (let ((key (read-key)))
        (case (key-to-char key)
          (#\s
           (lem-yath-surround-change))
          (#\c
           (call-command 'lem-yath-change-lines argument))
          (otherwise
           (call-vi-operator 'lem-vi-mode/commands:vi-change argument key))))))

(define-key lem-vi-mode:*visual-keymap* "S" 'lem-yath-surround-operator)
(define-key lem-vi-mode:*normal-keymap* "y" 'lem-yath-yank-or-surround)
(define-key lem-vi-mode:*normal-keymap* "Y" 'lem-yath-yank-lines)
(define-key lem-vi-mode:*normal-keymap* "d" 'lem-yath-delete-or-surround)
(define-key lem-vi-mode:*normal-keymap* "c" 'lem-yath-change-or-surround)

;;; --- snipe (evil-snipe): s/S 2-char incremental motion ----------------------

(defvar *last-snipe-target* nil)

(defun visible-snipe-bounds ()
  "Return temporary points bounding the current visible window."
  (let* ((window (current-window))
         (top (copy-point (window-view-point window) :temporary))
         (bottom (copy-point top :temporary)))
    (line-start top)
    (or (line-offset bottom (window-height window))
        (buffer-end bottom))
    (values top bottom)))

(defun read-snipe-target ()
  (let ((c1 (read-vi-character "Snipe: ")))
    (coerce (list c1 (read-vi-character (format nil "Snipe: ~a" c1)))
            'string)))

(defun perform-snipe (target direction)
  "Move to TARGET in DIRECTION within the visible window."
  (multiple-value-bind (top bottom) (visible-snipe-bounds)
    (with-point ((p (current-point)))
      (let ((found
              (ecase direction
                (:forward
                 (character-offset p 1)
                 (when (search-forward p target bottom)
                   (character-offset p (- (length target)))
                   p))
                (:backward
                 (search-backward p target top)))))
        (if found
            (progn
              (setf *last-snipe-target* target)
              (move-point (current-point) p)
              t)
            (progn
              (message "snipe: ~a not found" target)
              nil))))))

(defun new-snipe (direction)
  (perform-snipe (read-snipe-target) direction))

(defun repeat-or-new-snipe (direction)
  (if *last-snipe-target*
      (perform-snipe *last-snipe-target* direction)
      (new-snipe direction)))

(lem-vi-mode:define-motion lem-yath-snipe-forward () ()
  (:type :inclusive)
  (repeat-or-new-snipe :forward))

(lem-vi-mode:define-motion lem-yath-snipe-backward () ()
  (:type :inclusive)
  (repeat-or-new-snipe :backward))

(lem-vi-mode:define-motion lem-yath-snipe-operator-forward () ()
  (:type :inclusive)
  (new-snipe :forward))

(lem-vi-mode:define-motion lem-yath-snipe-operator-backward () ()
  (:type :inclusive)
  (new-snipe :backward))

(lem-vi-mode:define-motion lem-yath-snipe-operator-forward-exclusive () ()
  (:type :exclusive)
  (new-snipe :forward))

(lem-vi-mode:define-motion lem-yath-snipe-operator-backward-exclusive () ()
  (:type :exclusive)
  (new-snipe :backward))

(define-command lem-yath-snipe-repeat () ()
  "Repeat the last snipe or native f/t search forward."
  (if *last-snipe-target*
      (perform-snipe *last-snipe-target* :forward)
      (call-command 'lem-vi-mode/commands:vi-find-char-repeat nil)))

(define-command lem-yath-snipe-repeat-backward () ()
  "Repeat the last snipe or native f/t search backward."
  (if *last-snipe-target*
      (perform-snipe *last-snipe-target* :backward)
      (call-command 'lem-vi-mode/commands:vi-find-char-repeat-backward nil)))

(defun clear-stale-snipe-repeat ()
  (unless (member (command-name (this-command))
                  '(lem-yath-snipe-forward
                    lem-yath-snipe-backward
                    lem-yath-snipe-repeat
                    lem-yath-snipe-repeat-backward))
    (setf *last-snipe-target* nil)))

(add-hook *post-command-hook* 'clear-stale-snipe-repeat)

(define-key lem-vi-mode:*normal-keymap* "s" 'lem-yath-snipe-forward)
(define-key lem-vi-mode:*normal-keymap* "S" 'lem-yath-snipe-backward)
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

;;; --- structural editing for lisp buffers (lispy/lispyville) -----------------

(defun enable-paredit ()
  (lem-paredit-mode:paredit-mode t))

(add-hook lem-lisp-mode:*lisp-mode-hook* 'enable-paredit)
