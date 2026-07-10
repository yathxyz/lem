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
;;; Visual `S` wraps the selection; `g s {motion}` wraps a motion;
;;; `d s {char}` deletes the nearest pair; `c s {old}{new}` changes it.
;;; (Plain ys/cs/ds key chords collide with vi operators y/c/d, which read a
;;; motion next -- so the port uses these adjacent chords.)

(defparameter *surround-pairs*
  '((#\( "(" ")") (#\) "(" ")") (#\b "(" ")")
    (#\[ "[" "]") (#\] "[" "]")
    (#\{ "{" "}") (#\} "{" "}") (#\B "{" "}")
    (#\< "<" ">") (#\> "<" ">")
    (#\" "\"" "\"") (#\' "'" "'") (#\` "`" "`")))

(defun surround-pair (char)
  (let ((entry (assoc char *surround-pairs*)))
    (if entry
        (values (second entry) (third entry))
        (let ((s (string char)))
          (values s s)))))

(lem-vi-mode:define-operator lem-yath-surround-operator (start end type) ("<R>")
    (:move-point nil)
  (multiple-value-bind (open close)
      (surround-pair (prompt-for-character "Surround with: "))
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

(define-command lem-yath-surround-delete () ()
  "Delete the nearest surrounding pair (ds in evil-surround)."
  (multiple-value-bind (open close)
      (surround-pair (prompt-for-character "Delete surround: "))
    (multiple-value-bind (s e) (find-surrounding open close)
      (cond ((and s e)
             ;; Delete the closer first so the opener's position stays valid.
             (character-offset e (- (length close)))
             (delete-character e (length close))
             (delete-character s (length open)))
            (t
             (message "No surrounding ~a...~a found" open close))))))

(define-command lem-yath-surround-change () ()
  "Change the nearest surrounding pair (cs in evil-surround)."
  (multiple-value-bind (old-open old-close)
      (surround-pair (prompt-for-character "Change surround: "))
    (multiple-value-bind (new-open new-close)
        (surround-pair (prompt-for-character (format nil "Replace ~a...~a with: "
                                                     old-open old-close)))
      (multiple-value-bind (s e) (find-surrounding old-open old-close)
        (cond ((and s e)
               (character-offset e (- (length old-close)))
               (delete-character e (length old-close))
               (insert-string e new-close)
               (delete-character s (length old-open))
               (insert-string s new-open))
              (t
               (message "No surrounding ~a...~a found" old-open old-close)))))))

(define-key lem-vi-mode:*visual-keymap* "S" 'lem-yath-surround-operator)
(define-key lem-vi-mode:*normal-keymap* "g s" 'lem-yath-surround-operator)
(define-key lem-vi-mode:*normal-keymap* "d s" 'lem-yath-surround-delete)
(define-key lem-vi-mode:*normal-keymap* "c s" 'lem-yath-surround-change)

;;; --- snipe (evil-snipe): s/S 2-char incremental motion ----------------------

(defun snipe (direction)
  (let* ((c1 (prompt-for-character "Snipe: "))
         (c2 (prompt-for-character (format nil "Snipe: ~a" c1)))
         (target (coerce (list c1 c2) 'string)))
    (with-point ((p (current-point)))
      (ecase direction
        (:forward
         (character-offset p 1)
         (if (search-forward p target)
             (progn (character-offset p (- (length target)))
                    (move-point (current-point) p))
             (message "snipe: ~a not found" target)))
        (:backward
         (if (search-backward p target)
             (move-point (current-point) p)
             (message "snipe: ~a not found" target)))))))

(define-command lem-yath-snipe-forward () ()
  "Jump forward to a 2-character sequence (evil-snipe `s`)."
  (snipe :forward))

(define-command lem-yath-snipe-backward () ()
  "Jump backward to a 2-character sequence (evil-snipe `S`)."
  (snipe :backward))

(define-key lem-vi-mode:*normal-keymap* "s" 'lem-yath-snipe-forward)
(define-key lem-vi-mode:*normal-keymap* "S" 'lem-yath-snipe-backward)

;;; --- structural editing for lisp buffers (lispy/lispyville) -----------------

(defun enable-paredit ()
  (lem-paredit-mode:paredit-mode t))

(add-hook lem-lisp-mode:*lisp-mode-hook* 'enable-paredit)
