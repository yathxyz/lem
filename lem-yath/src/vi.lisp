;;;; Modal editing: evil -> lem-vi-mode.
;;;; Covers: vi-mode activation, SPC as leader, the `gc` comment operator
;;;; (evil-nerd-commenter), surround (evil-surround) and a 2-char snipe
;;;; (evil-snipe). Leader bindings themselves live in keybindings.lisp.

(in-package :lem-yath)

(lem-vi-mode:vi-mode)

;; Match Evil's `evil-respect-visual-line-mode': the buffer-local wrapping
;; switch changes Vi's screen/logical line policy instead of only changing
;; rendering.
(setf (variable-value
       'lem-vi-mode/visual:respect-visual-line-mode :global)
      t)

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

(defun surround-quoted-state-p (state)
  (member (pps-state-type state) '(:string :block-string :fence)))

(defun surround-syntax-domain (point)
  "Return POINT's syntax container, or :CODE outside quoted/comment domains."
  (let* ((state (syntax-ppss point))
         (start (pps-state-token-start-point state)))
    (cond
      ((and start (pps-state-string-p state))
       (list :string (position-at-point start)))
      ((and start (pps-state-comment-p state))
       (list :comment (position-at-point start)))
      ((and start (eq :fence (pps-state-type state)))
       (list :fence (position-at-point start)))
      (t
       :code))))

(defun surround-relevant-domain-p (domain target-domain)
  "Whether DOMAIN can contain a target in TARGET-DOMAIN.

Code delimiters can surround text inside a quoted or comment domain, while
delimiters inside an unrelated syntax container must not impersonate code
structure."
  (or (eq domain :code)
      (equal domain target-domain)))

(defun surround-candidate-encloses-p (start end position)
  (and (<= start position)
       (< position end)))

(defun surround-unescaped-character-p (point character)
  (and (eql (character-at point) character)
       (not (syntax-escape-point-p point 0))))

(defun surround-string-state (point quote)
  "Return POINT's syntax string state when its opener is QUOTE."
  (labels ((matching-start (state)
             (alexandria:when-let ((start
                                    (and (surround-quoted-state-p state)
                                         (pps-state-token-start-point state))))
               (when (eql (character-at start) quote)
                 state))))
    (or (matching-start (syntax-ppss point))
        (when (eql (character-at point) quote)
          (with-point ((after point))
            (when (character-offset after 1)
              (alexandria:when-let ((state
                                     (matching-start (syntax-ppss after))))
                (when (point= (pps-state-token-start-point state) point)
                  state))))))))

(defun surround-string-start (point quote)
  "Return the syntax string opener around POINT when it is QUOTE."
  (alexandria:when-let ((state (surround-string-state point quote)))
    (position-at-point (pps-state-token-start-point state))))

(defun surround-syntax-string-candidate (point quote)
  "Return the syntax string delimited by QUOTE around POINT as positions."
  (alexandria:when-let ((start-position (surround-string-start point quote)))
    (let ((buffer (point-buffer point))
          (target-position (position-at-point point)))
      (with-point ((start (buffer-start-point buffer))
                   (scan (buffer-start-point buffer))
                   (limit (buffer-end-point buffer)))
        (move-to-position start start-position)
        (move-point scan start)
        (character-offset scan 1)
        (loop :while (point< scan limit)
              :when (and (surround-unescaped-character-p scan quote)
                         (let* ((state (syntax-ppss scan))
                                (token-start
                                  (and (surround-quoted-state-p state)
                                       (pps-state-token-start-point state))))
                           (and token-start (point= token-start start))))
                :do (let ((candidate
                            (list start-position
                                  (1+ (position-at-point scan)))))
                      (return
                        (when (surround-candidate-encloses-p
                               (first candidate) (second candidate)
                               target-position)
                          candidate)))
              :do (character-offset scan 1))))))

(defun surround-syntax-string-boundary-p (point quote)
  "Whether QUOTE at POINT opens or closes a syntax-table string."
  (or (let* ((state (syntax-ppss point))
             (start (and (surround-quoted-state-p state)
                         (pps-state-token-start-point state))))
        (and start (eql (character-at start) quote)))
      (with-point ((after point))
        (and (character-offset after 1)
             (let* ((state (syntax-ppss after))
                    (start (and (surround-quoted-state-p state)
                                (pps-state-token-start-point state))))
               (and start
                    (point= start point)
                    (eql (character-at start) quote)))))))

(defun surround-asymmetric-candidate (point open close)
  "Return the narrowest balanced OPEN/CLOSE pair enclosing POINT."
  (let* ((buffer (point-buffer point))
         (target-position (position-at-point point))
         (target-domain (surround-syntax-domain point))
         (stacks (make-hash-table :test 'equal)))
    (with-point ((scan (buffer-start-point buffer))
                 (limit (buffer-end-point buffer)))
      (loop :while (point< scan limit)
            :for opener-p := (surround-unescaped-character-p scan open)
            :for closer-p := (surround-unescaped-character-p scan close)
            :when (or opener-p closer-p)
              :do (let ((domain (surround-syntax-domain scan)))
                    (when (surround-relevant-domain-p domain target-domain)
                      (cond
                        (opener-p
                         (push (position-at-point scan)
                               (gethash domain stacks)))
                        (closer-p
                         (alexandria:when-let
                             ((start (pop (gethash domain stacks))))
                           (let ((candidate
                                   (list start
                                         (1+ (position-at-point scan)))))
                             (when (surround-candidate-encloses-p
                                    (first candidate) (second candidate)
                                    target-position)
                               (return candidate))))))))
            :do (character-offset scan 1)))))

(defun surround-symmetric-candidate (point quote)
  "Return the narrowest unescaped QUOTE pair enclosing POINT."
  ;; A one-character surround command cannot safely replace only the outer
  ;; characters of a multi-character syntax delimiter such as Python's
  ;; triple quote.  Leave it untouched until the surround grammar can carry
  ;; complete delimiter strings.
  (when (eq :block-string
            (alexandria:when-let ((state
                                   (surround-string-state point quote)))
              (pps-state-type state)))
    (return-from surround-symmetric-candidate nil))
  (alexandria:when-let ((candidate
                         (surround-syntax-string-candidate point quote)))
    (return-from surround-symmetric-candidate candidate))
  (let* ((buffer (point-buffer point))
         (target-position (position-at-point point))
         (target-domain (surround-syntax-domain point))
         (opens (make-hash-table :test 'equal)))
    (with-point ((scan (buffer-start-point buffer))
                 (limit (buffer-end-point buffer)))
      (loop :while (point< scan limit)
            :when (surround-unescaped-character-p scan quote)
              :do (let ((domain (surround-syntax-domain scan)))
                    (when (and (surround-relevant-domain-p
                                domain target-domain)
                               (not (surround-syntax-string-boundary-p
                                     scan quote)))
                      (multiple-value-bind (start present-p)
                          (gethash domain opens)
                        (if present-p
                            (let ((candidate
                                    (list start
                                          (1+ (position-at-point scan)))))
                              (remhash domain opens)
                              (when (surround-candidate-encloses-p
                                     (first candidate) (second candidate)
                                     target-position)
                                (return candidate)))
                            (setf (gethash domain opens)
                                  (position-at-point scan))))))
            :do (character-offset scan 1)))))

(defun surround-candidate-points (buffer candidate)
  (when candidate
    (with-point ((start (buffer-start-point buffer))
                 (end (buffer-start-point buffer)))
      (when (and (move-to-position start (first candidate))
                 (move-to-position end (second candidate)))
        (values (copy-point start :temporary)
                (copy-point end :temporary))))))

(defun find-surrounding (open close)
  "Return the narrowest balanced OPEN/CLOSE pair enclosing point.

Escaped delimiters are ignored.  Delimiters in unrelated strings, comments, or
fences cannot pair with code delimiters, but code delimiters may still surround
a target inside one of those syntax domains."
  (unless (and (= 1 (length open)) (= 1 (length close)))
    (editor-error "Only character surround pairs are supported"))
  (let* ((point (current-point))
         (open-character (char open 0))
         (close-character (char close 0))
         (candidate
           (if (char= open-character close-character)
               (surround-symmetric-candidate point open-character)
               (surround-asymmetric-candidate
                point open-character close-character))))
    (surround-candidate-points (point-buffer point) candidate)))

(defun surrounding-edit-ranges (start end open close trim-padding)
  "Return the disjoint opener and closer ranges that should be replaced."
  (with-point ((open-end start)
               (close-start end)
               (padded-open-end start))
    (unless (and (character-offset open-end (length open))
                 (character-offset close-start (- (length close)))
                 (string= open (points-to-string start open-end))
                 (string= close (points-to-string close-start end)))
      (editor-error "Surrounding delimiters changed before editing"))
    (when (and trim-padding
               (eql (character-at close-start -1) #\Space))
      (character-offset close-start -1))
    (when (and trim-padding
               (eql (character-at open-end) #\Space))
      (move-point padded-open-end open-end)
      (character-offset padded-open-end 1)
      (when (point<= padded-open-end close-start)
        (move-point open-end padded-open-end)))
    (unless (point<= open-end close-start)
      (editor-error "Surrounding delimiter ranges overlap"))
    (values (copy-point start :temporary)
            (copy-point open-end :temporary)
            (copy-point close-start :temporary)
            (copy-point end :temporary))))

(defun ensure-surround-ranges-writable
    (open-start open-end close-start close-end &key replacement)
  "Preflight both disjoint surround mutations before changing either one."
  (unless lem/buffer/internal:*inhibit-read-only*
    (lem/buffer/internal::check-read-only-buffer
     (point-buffer open-start))
    (lem/buffer/internal::check-read-only-at-point
     open-start (count-characters open-start open-end))
    (lem/buffer/internal::check-read-only-at-point
     close-start (count-characters close-start close-end))
    ;; Replacement inserts where the ranges end up after deletion.  Adjacent
    ;; read-only text can shift onto those points, so preflight that future
    ;; state before changing the closer.
    (when replacement
      (lem/buffer/internal::check-read-only-at-point open-end 0)
      (lem/buffer/internal::check-read-only-at-point close-end 0))))

(defun remove-surrounding (start end open close trim-padding)
  "Remove OPEN and CLOSE at START and END, optionally removing inner spaces."
  (multiple-value-bind (open-start open-end close-start close-end)
      (surrounding-edit-ranges start end open close trim-padding)
    (ensure-surround-ranges-writable
     open-start open-end close-start close-end)
    (delete-between-points close-start close-end)
    (delete-between-points open-start open-end)))

(defun change-surrounding-pair (start end old-open old-close
                                new-open new-close trim-padding)
  "Replace a surrounding pair without relying on points shifted by edits."
  (multiple-value-bind (open-start open-end close-start close-end)
      (surrounding-edit-ranges
       start end old-open old-close trim-padding)
    (ensure-surround-ranges-writable
     open-start open-end close-start close-end :replacement t)
    (delete-between-points close-start close-end)
    (insert-string close-start new-close)
    (delete-between-points open-start open-end)
    (insert-string open-start new-open)))

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
      (multiple-value-bind (s e) (find-surrounding old-open old-close)
        (if (and s e)
            (multiple-value-bind (new-open new-close)
                (surround-insertion-pair
                 (read-vi-character (format nil "Replace ~a...~a with: "
                                            old-open old-close)))
              (change-surrounding-pair
               s e old-open old-close new-open new-close
               (spaced-surround-character-p old-char)))
            (message "No surrounding ~a...~a found"
                     old-open old-close))))))

(defun call-vi-operator (command argument key)
  "Run native vi operator COMMAND with ARGUMENT after restoring KEY."
  (unread-key key)
  (call-command command argument))

(defun lem-yath-screen-line-policy-p ()
  (lem-vi-mode/visual:respect-visual-line-mode-p))

(defun lem-yath-before-indentation-p (point)
  "Whether POINT is no later than its logical line's first nonblank."
  (with-point ((indentation point))
    (back-to-indentation indentation)
    (point<= point indentation)))

(defun lem-yath-screen-motion-range (origin destination)
  "Return Evil's normalized exclusive screen motion range."
  (with-point ((start origin)
               (end destination))
    (when (point< end start)
      (rotatef start end))
    (cond
      ((and (point/= start end)
            (start-line-p end))
       ;; Evil normalizes an exclusive motion landing at logical BOL.  From
       ;; indentation it becomes the preceding logical line; otherwise it is
       ;; inclusive through that line's terminator.
       (character-offset end -1)
       (lem-vi-mode/core:make-range
        (copy-point start :temporary)
        (copy-point end :temporary)
        (if (lem-yath-before-indentation-p start) :line :inclusive)))
      (t
       (lem-vi-mode/core:make-range
        (copy-point start :temporary)
        (copy-point end :temporary)
        :exclusive)))))

(defun lem-yath-vertical-motion-range (count direction screen-first-p)
  "Move COUNT rows in DIRECTION and return the effective Vi motion range.
SCREEN-FIRST-P means use displayed rows while the configured wrapping policy
is active; false implements the inverse g-j/g-k mapping."
  (let ((screen-p (if screen-first-p
                      (lem-yath-screen-line-policy-p)
                      (not (lem-yath-screen-line-policy-p)))))
    (with-point ((origin (current-point)))
      (alexandria:ignore-some-conditions (beginning-of-buffer end-of-buffer)
        (ecase direction
          (:forward
           (if screen-p (next-line count) (next-logical-line count)))
          (:backward
           (if screen-p (previous-line count) (previous-logical-line count)))))
      (if screen-p
          (lem-yath-screen-motion-range origin (current-point))
          (lem-vi-mode/core:make-range
           (copy-point origin :temporary)
           (copy-point (current-point) :temporary)
           :line)))))

(lem-vi-mode:define-motion lem-yath-next-line (&optional (n 1)) (:universal)
  ()
  (lem-yath-vertical-motion-range n :forward t))

(lem-vi-mode:define-motion lem-yath-previous-line (&optional (n 1)) (:universal)
  ()
  (lem-yath-vertical-motion-range n :backward t))

(lem-vi-mode:define-motion lem-yath-next-g-line (&optional (n 1)) (:universal)
  ()
  (lem-yath-vertical-motion-range n :forward nil))

(lem-vi-mode:define-motion lem-yath-previous-g-line (&optional (n 1)) (:universal)
  ()
  (lem-yath-vertical-motion-range n :backward nil))

(defun lem-yath-zero-target (point)
  (if (lem-yath-screen-line-policy-p)
      (lem-vi-mode/visual:screen-line-start point)
      (line-start (copy-point point :temporary))))

(define-command lem-yath-zero () ()
  "Move to strict screen or logical column zero, respecting wrapping."
  (if (mode-active-p (current-buffer) 'lem/universal-argument:universal-argument)
      (lem/universal-argument:universal-argument-0)
      (move-point (current-point) (lem-yath-zero-target (current-point)))))

(lem-vi-mode:define-motion lem-yath-zero-motion () ()
  (:type :exclusive)
  (with-point ((origin (current-point)))
    (move-point (current-point) (lem-yath-zero-target (current-point)))
    (lem-vi-mode/core:make-range
     (copy-point origin :temporary)
     (copy-point (current-point) :temporary)
     :exclusive)))

(define-command lem-yath-g-zero () ()
  "Move to the inverse strict logical or screen column zero."
  (move-point
   (current-point)
   (if (lem-yath-screen-line-policy-p)
       (line-start (copy-point (current-point) :temporary))
       (lem-vi-mode/visual:screen-line-start (current-point)))))

(defun lem-yath-move-to-screen-line-end (count)
  (when (> count 1)
    (unless (move-to-next-virtual-line
             (current-point) (1- count) (current-window))
      (buffer-end (current-point))))
  (move-to-end-of-line))

(defun lem-yath-move-to-logical-line-end (count)
  (when (> count 1)
    (alexandria:ignore-some-conditions (end-of-buffer)
      (next-logical-line (1- count))))
  (line-end (current-point)))

(defun lem-yath-end-motion-range (count screen-first-p)
  (let ((screen-p (if screen-first-p
                      (lem-yath-screen-line-policy-p)
                      (not (lem-yath-screen-line-policy-p)))))
    (with-point ((origin (current-point)))
      (if screen-p
          (lem-yath-move-to-screen-line-end count)
          (lem-yath-move-to-logical-line-end count))
      (lem-vi-mode/core:make-range
       (copy-point origin :temporary)
       (copy-point (current-point) :temporary)
       (if screen-p :inclusive :exclusive)))))

(lem-vi-mode:define-motion lem-yath-end-of-line (&optional (n 1)) (:universal)
  ()
  (lem-yath-end-motion-range n t))

(lem-vi-mode:define-motion lem-yath-g-end-of-line (&optional (n 1)) (:universal)
  ()
  (lem-yath-end-motion-range n nil))

(define-command lem-yath-visual-line () ()
  (call-command
   (if (lem-yath-screen-line-policy-p)
       'lem-vi-mode/visual:vi-visual-screen-line
       'lem-vi-mode/visual:vi-visual-line)
   nil))

(define-command lem-yath-insert-line () ()
  "Enter insert at indentation or the active displayed-row start."
  (if (not (lem-yath-screen-line-policy-p))
      (lem-vi-mode/commands:vi-insert-line)
      (with-point ((indentation (current-point))
                   (screen-start (current-point)))
        (back-to-indentation indentation)
        (move-point screen-start
                    (lem-vi-mode/visual:screen-line-start screen-start))
        (move-point (current-point)
                    (if (point< indentation screen-start)
                        screen-start
                        indentation))
        (setf (lem-vi-mode/core:buffer-state)
              'lem-vi-mode/states::insert))))

(define-command lem-yath-append-line () ()
  "Enter insert at the active displayed-row or logical line end."
  (if (lem-yath-screen-line-policy-p)
      (with-point ((logical-end (current-point)))
        (line-end logical-end)
        (let ((screen-end
                (lem-vi-mode/visual:screen-line-end (current-point))))
          ;; The exclusive end of a logical line's final displayed row is the
          ;; next line's BOL.  A inserts before that newline, not after it.
          (move-point (current-point)
                      (if (point< logical-end screen-end)
                          logical-end
                          screen-end))))
      (line-end (current-point)))
  (setf (lem-vi-mode/core:buffer-state) 'lem-vi-mode/states::insert))

(lem-vi-mode:define-motion lem-yath-line-motion (&optional (n 1)) (:universal)
  (:type :line)
  (with-point ((origin (current-point)))
    (if (lem-yath-screen-line-policy-p)
        (when (> n 1)
          (alexandria:ignore-some-conditions (end-of-buffer)
            (next-line (1- n))))
        (alexandria:ignore-some-conditions (end-of-buffer)
          (next-logical-line (1- n))))
    (lem-vi-mode/core:make-range
     (copy-point origin :temporary)
     (copy-point (current-point) :temporary)
     (if (lem-yath-screen-line-policy-p) :screen-line :line))))

(defun lem-yath-expand-line-based-visual-range (start end type)
  "Expand a character Visual range for D, C, or Y like Evil."
  (if (or (not (lem-vi-mode/visual:visual-p))
          (member type '(:line :screen-line :block)))
      (values start end type)
      (with-point ((last end))
        (when (point< start last)
          (character-offset last -1))
        (if (lem-yath-screen-line-policy-p)
            (destructuring-bind (screen-start screen-end)
                (lem-vi-mode/visual:screen-line-range start last)
              (values screen-start screen-end :screen-line))
            (with-point ((line-start start)
                         (line-end last))
              (line-start line-start)
              (or (line-offset line-end 1 0)
                  (line-end line-end))
              (values line-start line-end :line))))))

(lem-vi-mode:define-operator lem-yath-yank-lines (start end type) ("<R>")
  (:motion lem-yath-line-motion :move-point nil)
  (multiple-value-setq (start end type)
    (lem-yath-expand-line-based-visual-range start end type))
  (lem-vi-mode/commands:vi-yank start end type))

(lem-vi-mode:define-operator lem-yath-delete-lines (start end type) ("<R>")
  (:motion lem-yath-line-motion :move-point nil)
  (let ((lem-core::*this-command*
          (get-command 'lem-vi-mode/commands:vi-delete)))
    (lem-vi-mode/commands:vi-delete start end type)))

(lem-vi-mode:define-operator lem-yath-change-lines (start end type) ("<R>")
  (:motion lem-yath-line-motion :move-point nil)
  (lem-vi-mode/commands:vi-change start end type))

(lem-vi-mode:define-operator lem-yath-delete-to-line-end
    (start end type) ("<R>")
  (:motion lem-yath-end-of-line :move-point nil)
  (multiple-value-setq (start end type)
    (lem-yath-expand-line-based-visual-range start end type))
  (let ((lem-core::*this-command*
          (get-command 'lem-vi-mode/commands:vi-delete)))
    (lem-vi-mode/commands:vi-delete start end type)))

(lem-vi-mode:define-operator lem-yath-change-to-line-end
    (start end type) ("<R>")
  (:motion lem-yath-end-of-line :move-point nil)
  (multiple-value-setq (start end type)
    (lem-yath-expand-line-based-visual-range start end type))
  (lem-vi-mode/commands:vi-change start end type))

(lem-vi-mode:define-operator lem-yath-yank-to-zero (start end type) ("<R>")
  (:motion lem-yath-zero-motion :move-point nil)
  (lem-vi-mode/commands:vi-yank start end type))

(lem-vi-mode:define-operator lem-yath-delete-to-zero (start end type) ("<R>")
  (:motion lem-yath-zero-motion :move-point nil)
  (let ((lem-core::*this-command*
          (get-command 'lem-vi-mode/commands:vi-delete)))
    (lem-vi-mode/commands:vi-delete start end type)))

(lem-vi-mode:define-operator lem-yath-change-to-zero (start end type) ("<R>")
  (:motion lem-yath-zero-motion :move-point nil)
  (lem-vi-mode/commands:vi-change start end type))

(defun lem-yath-read-operator-key (argument)
  "Read an optional motion count and return its key and combined count."
  (let* ((key (read-key))
         (character (key-to-char key))
         (first-digit (and character (digit-char-p character))))
    ;; A leading zero is the `0' motion.  Counts start at 1..9, though later
    ;; digits may contain zero (for example, d10j).
    (if (and first-digit (plusp first-digit))
        (loop :with motion-count := first-digit
              :for next-key := (read-key)
              :for next-character := (key-to-char next-key)
              :for next-digit := (and next-character
                                      (digit-char-p next-character))
              :while next-digit
              :do (setf motion-count
                        (+ (* motion-count 10) next-digit))
              :finally
                 (return
                   (values next-key
                           (* (or argument 1) motion-count)
                           t)))
        (values key argument nil))))

(define-command lem-yath-yank-or-surround (argument) (:universal-nil)
  "Run native `y`, or evil-surround `ys` when followed by s."
  (if (lem-vi-mode/visual:visual-p)
      (call-command (if (structural-editing-p)
                        'lem-yath-structural-yank
                        'lem-vi-mode/commands:vi-yank)
                    argument)
      (multiple-value-bind (key combined-argument counted-p)
          (lem-yath-read-operator-key argument)
        (case (key-to-char key)
          (#\s
           (if counted-p
               (call-vi-operator
                (if (structural-editing-p)
                    'lem-yath-structural-yank
                    'lem-vi-mode/commands:vi-yank)
                combined-argument key)
               (call-command 'lem-yath-surround-operator argument)))
          (#\y
           (call-command (if (structural-editing-p)
                             'lem-yath-structural-yank-lines
                             'lem-yath-yank-lines)
                         combined-argument))
          (#\0
           (call-command (if (structural-editing-p)
                             'lem-yath-structural-yank-to-zero
                             'lem-yath-yank-to-zero)
                         combined-argument))
          (otherwise
           (call-vi-operator (if (structural-editing-p)
                                 'lem-yath-structural-yank
                                 'lem-vi-mode/commands:vi-yank)
                             combined-argument key))))))

(define-command lem-yath-delete-or-surround (argument) (:universal-nil)
  "Run native `d`, or evil-surround `ds` when followed by s."
  (if (lem-vi-mode/visual:visual-p)
      (call-command (if (structural-editing-p)
                        'lem-yath-structural-delete
                        'lem-vi-mode/commands:vi-delete)
                    argument)
      (multiple-value-bind (key combined-argument counted-p)
          (lem-yath-read-operator-key argument)
        (case (key-to-char key)
          (#\s
           (if counted-p
               (call-vi-operator
                (if (structural-editing-p)
                    'lem-yath-structural-delete
                    'lem-vi-mode/commands:vi-delete)
                combined-argument key)
               (lem-yath-surround-delete)))
          (#\d
           (call-command (if (structural-editing-p)
                             'lem-yath-structural-delete-lines
                             'lem-yath-delete-lines)
                         combined-argument))
          (#\0
           (call-command (if (structural-editing-p)
                             'lem-yath-structural-delete-to-zero
                             'lem-yath-delete-to-zero)
                         combined-argument))
          (otherwise
           (call-vi-operator (if (structural-editing-p)
                                 'lem-yath-structural-delete
                                 'lem-vi-mode/commands:vi-delete)
                             combined-argument key))))))

(define-command lem-yath-change-or-surround (argument) (:universal-nil)
  "Run native `c`, or evil-surround `cs` when followed by s."
  (if (lem-vi-mode/visual:visual-p)
      (call-command (if (structural-editing-p)
                        'lem-yath-structural-change
                        'lem-vi-mode/commands:vi-change)
                    argument)
      (multiple-value-bind (key combined-argument counted-p)
          (lem-yath-read-operator-key argument)
        (case (key-to-char key)
          (#\s
           (if counted-p
               (call-vi-operator
                (if (structural-editing-p)
                    'lem-yath-structural-change
                    'lem-vi-mode/commands:vi-change)
                combined-argument key)
               (lem-yath-surround-change)))
          (#\c
           (call-command (if (structural-editing-p)
                             'lem-yath-structural-change-lines
                             'lem-yath-change-lines)
                         combined-argument))
          (#\0
           (call-command (if (structural-editing-p)
                             'lem-yath-structural-change-to-zero
                             'lem-yath-change-to-zero)
                         combined-argument))
          (otherwise
           (call-vi-operator (if (structural-editing-p)
                                 'lem-yath-structural-change
                                 'lem-vi-mode/commands:vi-change)
                             combined-argument key))))))

(define-command lem-yath-yank-line-dispatch (argument) (:universal-nil)
  "Use Lispyville's safe y$ in structural buffers and Vim's whole-line Y elsewhere."
  (call-command (if (structural-editing-p)
                    'lem-yath-structural-yank-to-line-end
                    'lem-yath-yank-lines)
                argument))

(define-key lem-vi-mode:*visual-keymap* "S" 'lem-yath-surround-operator)
(define-key lem-vi-mode:*motion-keymap* "j" 'lem-yath-next-line)
(define-key lem-vi-mode:*motion-keymap* "k" 'lem-yath-previous-line)
(define-key lem-vi-mode:*motion-keymap* "g j" 'lem-yath-next-g-line)
(define-key lem-vi-mode:*motion-keymap* "g k" 'lem-yath-previous-g-line)
(define-key lem-vi-mode:*motion-keymap* "0" 'lem-yath-zero)
(define-key lem-vi-mode:*motion-keymap* "g 0" 'lem-yath-g-zero)
(define-key lem-vi-mode:*motion-keymap* "$" 'lem-yath-end-of-line)
(define-key lem-vi-mode:*motion-keymap* "g $" 'lem-yath-g-end-of-line)
(define-key lem-vi-mode:*motion-keymap* "V" 'lem-yath-visual-line)
(define-key lem-vi-mode:*normal-keymap* "y" 'lem-yath-yank-or-surround)
(define-key lem-vi-mode:*normal-keymap* "Y" 'lem-yath-yank-line-dispatch)
(define-key lem-vi-mode:*normal-keymap* "d" 'lem-yath-delete-or-surround)
(define-key lem-vi-mode:*normal-keymap* "c" 'lem-yath-change-or-surround)
(define-key lem-vi-mode:*normal-keymap* "D" 'lem-yath-delete-to-line-end)
(define-key lem-vi-mode:*normal-keymap* "C" 'lem-yath-change-to-line-end)
(define-key lem-vi-mode:*normal-keymap* "I" 'lem-yath-insert-line)
(define-key lem-vi-mode:*normal-keymap* "A" 'lem-yath-append-line)

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
