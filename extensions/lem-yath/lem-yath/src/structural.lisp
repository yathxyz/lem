;;;; Lispy/Lispyville parity for Lisp-family buffers.
;;;;
;;;; Paredit supplies the structural primitives.  This layer enables it for
;;;; every Lisp language used by the Emacs configuration and makes Vim
;;;; operators delimiter-safe in those buffers, following Lispyville's rule:
;;;; operate on every part of the requested region except unmatched
;;;; delimiters.

(in-package :lem-yath)

;;; --- activation -----------------------------------------------------------

(defun enable-structural-editing ()
  (lem-paredit-mode:paredit-mode t))

(add-hook lem-lisp-mode:*lisp-mode-hook* 'enable-structural-editing)
(add-hook lem-clojure-mode:*clojure-mode-hook* 'enable-structural-editing)
(add-hook lem-scheme-mode:*scheme-mode-hook* 'enable-structural-editing)
(add-hook lem-elisp-mode:*elisp-mode-hook* 'enable-structural-editing)

(defun structural-editing-p ()
  (mode-active-p (current-buffer) 'lem-paredit-mode:paredit-mode))

(defun structural-language-buffer-p (&optional (buffer (current-buffer)))
  (some (lambda (mode) (mode-active-p buffer mode))
        '(lem-lisp-mode:lisp-mode
          lem-clojure-mode:clojure-mode
          lem-scheme-mode:scheme-mode
          lem-elisp-mode:elisp-mode)))

(defun ensure-structural-editing (&optional buffer)
  "Enable Paredit after lazily loaded Lisp modes and buffer switches."
  (save-excursion
    (when buffer
      (setf (current-buffer) buffer))
    (when (and (structural-language-buffer-p)
               (not (structural-editing-p)))
      (enable-structural-editing))))

;; Some extension modes are loaded lazily after lem-yath, so their mode system
;; can replace an early hook variable.  These central hooks make activation
;; reliable regardless of package load order and also cover already-open files.
(add-hook *find-file-hook* 'ensure-structural-editing)
(add-hook *switch-to-buffer-hook* 'ensure-structural-editing)
(add-hook *post-command-hook* 'ensure-structural-editing)

;;; --- balanced-region analysis --------------------------------------------

(defun structural-unescaped-quote-p (point)
  (and (eql (character-at point) #\")
       (not (in-comment-p point))
       (not (syntax-escape-point-p point 0))))

(defun structural-unmatched-delimiters (start end)
  "Return temporary points for delimiters unmatched inside START..END."
  (let ((opens '())
        (unmatched '())
        (string-open nil))
    (with-point ((p start))
      (loop while (point< p end)
            for char = (character-at p)
            do (cond
                 ((structural-unescaped-quote-p p)
                  (cond ((in-string-p p)
                         (if string-open
                             (setf string-open nil)
                             (push (copy-point p :temporary) unmatched)))
                        (string-open
                         (push string-open unmatched)
                         (setf string-open nil))
                        (t
                         (setf string-open (copy-point p :temporary)))))
                 ((or (in-string-p p) (in-comment-p p)) nil)
                 ((syntax-open-paren-char-p char)
                  (push (copy-point p :temporary) opens))
                 ((syntax-closed-paren-char-p char)
                  (if (and opens
                           (syntax-equal-paren-p (first opens) p))
                      (pop opens)
                      (push (copy-point p :temporary) unmatched))))
               (character-offset p 1)))
    (when string-open
      (push string-open unmatched))
    (sort (nconc opens unmatched) #'point<)))

(defun structural-safe-regions (start end)
  "Return safe subregions of START..END in forward order.
Each unmatched delimiter becomes a one-character hole between regions."
  (let ((cursor (copy-point start :temporary))
        (regions '()))
    (dolist (unsafe (structural-unmatched-delimiters start end))
      (when (point< cursor unsafe)
        (push (list (copy-point cursor :temporary)
                    (copy-point unsafe :temporary))
              regions))
      (move-point cursor unsafe)
      (character-offset cursor 1))
    (when (point< cursor end)
      (push (list (copy-point cursor :temporary)
                  (copy-point end :temporary))
            regions))
    (nreverse regions)))

(defun structural-region-text (regions type)
  (let ((text (with-output-to-string (out)
                (dolist (region regions)
                  (write-string (points-to-string (first region)
                                                  (second region))
                                out)))))
    (if (and (eq type :line)
             (or (zerop (length text))
                 (not (eql (char text (1- (length text))) #\Newline))))
        (concatenate 'string text (string #\Newline))
        text)))

(defun structural-store-register (text type deletion-p start end)
  "Store TEXT in Vim's registers with TYPE and deletion semantics."
  (let ((target (lem-vi-mode/registers:take-selected-register)))
    (lem-vi-mode/registers::ensure-writable-register target)
    (unless (and target (char= target #\_))
      (copy-to-clipboard-with-killring text)
      (let* ((register-type (if (member type '(:line :block)) type :char))
             (item (lem-vi-mode/registers::make-yank text register-type)))
        (cond
          ((and target
                (lem-vi-mode/registers:named-register-p target))
           (when deletion-p
             (lem/common/ring:ring-push
              lem-vi-mode/registers::*deletion-history* item))
           (lem-vi-mode/registers::write-explicit-register target item))
          ((not deletion-p)
           (setf lem-vi-mode/registers::*yank-text* item
                 lem-vi-mode/registers::*unnamed-register* #\0))
          ((and (= (line-number-at-point start) (line-number-at-point end))
                (not (member type '(:line :block))))
           (setf lem-vi-mode/registers::*small-deletion-register* item
                 lem-vi-mode/registers::*unnamed-register* #\-))
          (t
           (lem/common/ring:ring-push
            lem-vi-mode/registers::*deletion-history* item)
           (setf lem-vi-mode/registers::*unnamed-register* #\1)))))))

(defun structural-safe-manipulate (start end type &key delete)
  "Yank or DELETE the balanced portions of START..END and return their text."
  (let* ((regions (structural-safe-regions start end))
         (text (structural-region-text regions type)))
    (structural-store-register text type delete start end)
    (when delete
      ;; Delete from the end so earlier point positions remain stable.
      (dolist (region (reverse regions))
        (delete-between-points (first region) (second region))))
    text))

;;; --- safe Vim operators ---------------------------------------------------

(lem-vi-mode:define-operator lem-yath-structural-yank (start end type) ("<R>")
    (:move-point nil)
  (structural-safe-manipulate start end type)
  (move-point (current-point) start))

(lem-vi-mode:define-operator lem-yath-structural-delete (start end type) ("<R>")
    (:move-point nil)
  (structural-safe-manipulate start end type :delete t)
  (move-point (current-point) start))

(lem-vi-mode:define-operator lem-yath-structural-change (start end type) ("<R>")
    (:move-point nil)
  (when (point/= start end)
    (structural-safe-manipulate start end type :delete t)
    (move-point (current-point) start)
    (setf (lem-vi-mode/core:buffer-state) 'lem-vi-mode/states::insert)))

(lem-vi-mode:define-operator lem-yath-structural-yank-lines (start end type) ("<R>")
    (:motion lem-yath-line-motion :move-point nil)
  (lem-yath-structural-yank start end type))

(lem-vi-mode:define-operator lem-yath-structural-delete-lines (start end type) ("<R>")
    (:motion lem-yath-line-motion :move-point nil)
  (lem-yath-structural-delete start end type))

(lem-vi-mode:define-operator lem-yath-structural-change-lines (start end type) ("<R>")
    (:motion lem-yath-line-motion :move-point nil)
  (if (eq type :screen-line)
      ;; Lispyville does not classify Evil's newer screen-line range as a
      ;; linewise register and changes it like a character region.
      (lem-yath-structural-change start end type)
      (progn
        (structural-safe-manipulate start end type :delete t)
        (move-point (current-point) start)
        ;; Lispyville keeps unmatched opening delimiters, enters after them,
        ;; and preserves a line boundary instead of joining the following form.
        (loop while (syntax-open-paren-char-p (character-at (current-point)))
              do (character-offset (current-point) 1))
        (unless (eql (character-at (current-point)) #\Newline)
          (insert-character (current-point) #\Newline)
          (character-offset (current-point) -1))
        (setf (lem-vi-mode/core:buffer-state)
              'lem-vi-mode/states::insert))))

(lem-vi-mode:define-operator lem-yath-structural-yank-to-zero
    (start end type) ("<R>")
  (:motion lem-yath-zero-motion :move-point nil)
  (lem-yath-structural-yank start end type))

(lem-vi-mode:define-operator lem-yath-structural-delete-to-zero
    (start end type) ("<R>")
  (:motion lem-yath-zero-motion :move-point nil)
  (lem-yath-structural-delete start end type))

(lem-vi-mode:define-operator lem-yath-structural-change-to-zero
    (start end type) ("<R>")
  (:motion lem-yath-zero-motion :move-point nil)
  (lem-yath-structural-change start end type))

(lem-vi-mode:define-motion lem-yath-to-line-end () ()
  (:type :inclusive)
  (line-end (current-point)))

(defun structural-line-end-exclusive (start)
  "Return the exclusive end of START's line without its newline."
  (with-point ((end start))
    (line-end end)
    (when (eql (character-at end -1) #\Newline)
      (character-offset end -1))
    (copy-point end :temporary)))

(lem-vi-mode:define-operator lem-yath-structural-yank-to-line-end
    (start end type) ("<R>")
    (:motion lem-yath-to-line-end :move-point nil)
  (declare (ignore end type))
  (lem-yath-structural-yank start (structural-line-end-exclusive start)
                            :exclusive))

(lem-vi-mode:define-operator lem-yath-structural-delete-to-line-end
    (start end type) ("<R>")
    (:motion lem-yath-to-line-end :move-point nil)
  (declare (ignore end type))
  (lem-yath-structural-delete start (structural-line-end-exclusive start)
                              :exclusive))

(lem-vi-mode:define-operator lem-yath-structural-change-to-line-end
    (start end type) ("<R>")
    (:motion lem-yath-to-line-end :move-point nil)
  (declare (ignore end type))
  (lem-yath-structural-change start (structural-line-end-exclusive start)
                              :exclusive))

;;; --- single-character safe deletion --------------------------------------

(defun structural-splice-delimiter-at-point ()
  "Splice the delimiter at point and its matching partner."
  (let ((point (current-point)))
    (cond
      ((syntax-open-paren-char-p (character-at point))
       (with-point ((end point))
         (scan-lists end 1 0)
         (character-offset end -1)
         (delete-character end 1)
         (delete-character point 1)))
      ((syntax-closed-paren-char-p (character-at point))
       (with-point ((start point))
         (character-offset start 1)
         (scan-lists start -1 0)
         (delete-character point 1)
         (delete-character start 1)))
      (t nil))))

(define-command lem-yath-structural-delete-next-char (argument) (:universal-nil)
  (if (not (structural-editing-p))
      (call-command 'lem-vi-mode/commands:vi-delete-next-char argument)
      (dotimes (_ (or argument 1))
        (if (or (syntax-open-paren-char-p (character-at (current-point)))
                (syntax-closed-paren-char-p (character-at (current-point))))
            (structural-splice-delimiter-at-point)
            (call-command 'lem-vi-mode/commands:vi-delete-next-char 1)))))

(define-command lem-yath-structural-delete-previous-char (argument) (:universal-nil)
  (if (not (structural-editing-p))
      (call-command 'lem-vi-mode/commands:vi-delete-previous-char argument)
      (dotimes (_ (or argument 1))
        (with-point ((previous (current-point)))
          (character-offset previous -1)
          (if (or (syntax-open-paren-char-p (character-at previous))
                  (syntax-closed-paren-char-p (character-at previous)))
              (progn
                (move-point (current-point) previous)
                (structural-splice-delimiter-at-point))
              (call-command 'lem-vi-mode/commands:vi-delete-previous-char 1))))))

;;; --- Lispyville key themes backed by Paredit ------------------------------

(defun structural-next-form-end (start)
  (with-point ((end start))
    (cond ((syntax-open-paren-char-p (character-at end))
           (scan-lists end 1 0))
          ((in-string-p end)
           (form-offset end 1))
          (t
           (let ((context (structural-atom-context end)))
             (loop while (and (not (end-buffer-p end))
                              (eq context (structural-atom-context end)))
                   do (character-offset end 1)))))
    (copy-point end :temporary)))

(defun structural-previous-form-start (end)
  (with-point ((start end))
    (skip-whitespace-backward start)
    (cond ((syntax-closed-paren-char-p (character-at start -1))
           (scan-lists start -1 0))
          (t
           (character-offset start -1)
           (let ((context (structural-atom-context start)))
             (loop while (not (start-buffer-p start))
                   do (with-point ((previous start))
                        (character-offset previous -1)
                        (if (eq context (structural-atom-context previous))
                            (move-point start previous)
                            (return)))))))
    (copy-point start :temporary)))

(defun structural-slurp-once ()
  (multiple-value-bind (start end) (structural-enclosing-list-bounds)
    (declare (ignore start))
    (when end
      (with-point ((close end)
                   (next-start end))
        (character-offset close -1)
        (skip-whitespace-forward next-start)
        (unless (or (end-buffer-p next-start)
                    (syntax-closed-paren-char-p (character-at next-start)))
          (with-point ((next-end (structural-next-form-end next-start)
                                 :left-inserting))
            (let ((delimiter (character-at close)))
              (delete-character close 1)
              (insert-character next-end delimiter)
              t)))))))

(defun structural-barf-once ()
  (multiple-value-bind (start end) (structural-enclosing-list-bounds)
    (declare (ignore start))
    (when end
      (with-point ((close end))
        (character-offset close -1)
        (let ((last-start (structural-previous-form-start close))
              (delimiter (character-at close)))
          (unless (point= last-start close)
            (delete-character close 1)
            (with-point ((insertion last-start))
              (skip-whitespace-backward insertion)
              (insert-character insertion delimiter))
            t))))))

(define-command lem-yath-structural-slurp (&optional (count 1)) (:universal)
  (dotimes (_ (or count 1))
    (unless (structural-slurp-once) (return))))

(define-command lem-yath-structural-barf (&optional (count 1)) (:universal)
  (dotimes (_ (or count 1))
    (unless (structural-barf-once) (return))))

(define-key lem-paredit-mode:*paredit-mode-keymap* ">"
  'lem-yath-structural-slurp)
(define-key lem-paredit-mode:*paredit-mode-keymap* "<"
  'lem-yath-structural-barf)
(define-key lem-paredit-mode:*paredit-mode-keymap* "M-s"
  'lem-paredit-mode:paredit-splice)
(define-key lem-paredit-mode:*paredit-mode-keymap* "M-r"
  'lem-paredit-mode:paredit-raise)
(define-key lem-paredit-mode:*paredit-mode-keymap* "M-t" 'transpose-sexps)

(define-command (lem-yath-structural-doublequote-dispatch
                 (:advice-classes lem-vi-mode/core:vi-command)
                 (:initargs :repeat t))
    (&optional count) (:universal-nil)
  "Keep Paredit smart quotes in Emacs/Insert state and Evil registers in Vi."
  (if (or (not (typep (current-global-mode) 'lem-vi-mode:vi-mode))
          (typep (lem-vi-mode/core:current-state)
                 'lem-vi-mode/states:insert))
      (call-command 'lem-paredit-mode:paredit-insert-doublequote nil)
      (call-command 'lem-vi-mode/commands:vi-use-register count)))

(define-key lem-paredit-mode:*paredit-mode-keymap* "\""
  'lem-yath-structural-doublequote-dispatch)

;;; --- Lispyville additional/additional-insert commands --------------------

(defun structural-enclosing-list-bounds (&optional (point (current-point)))
  "Return temporary points around the smallest list containing POINT."
  (with-point ((start point))
    (cond ((syntax-open-paren-char-p (character-at start)) nil)
          ((syntax-closed-paren-char-p (character-at start))
           (character-offset start 1)
           (scan-lists start -1 0))
          (t
           (scan-lists start -1 1)))
    (when (syntax-open-paren-char-p (character-at start))
      (with-point ((end start))
        (scan-lists end 1 0)
        (values (copy-point start :temporary)
                (copy-point end :temporary))))))

(defun structural-current-form-bounds ()
  "Return the atom or list operated on by Lispyville's additional commands."
  (with-point ((start (current-point)))
    (skip-whitespace-forward start)
    (cond
      ((syntax-open-paren-char-p (character-at start))
       (with-point ((end start))
         (scan-lists end 1 0)
         (values (copy-point start :temporary)
                 (copy-point end :temporary))))
      ((syntax-closed-paren-char-p (character-at start))
       (structural-enclosing-list-bounds start))
      (t
       (skip-symbol-backward start)
       (with-point ((end start))
         (when (form-offset end 1)
           (values (copy-point start :temporary)
                   (copy-point end :temporary))))))))

(defun structural-swap-forward-once ()
  (multiple-value-bind (start end) (structural-current-form-bounds)
    (when (and start end)
      (with-point ((next-start end))
        (skip-whitespace-forward next-start)
        (unless (or (end-buffer-p next-start)
                    (syntax-closed-paren-char-p (character-at next-start)))
          (with-point ((next-end next-start))
            (when (form-offset next-end 1)
              (let* ((offset (- (position-at-point (current-point))
                                (position-at-point start)))
                     (first (points-to-string start end))
                     (gap (points-to-string end next-start))
                     (second (points-to-string next-start next-end)))
                (delete-between-points start next-end)
                (insert-string start
                               (concatenate 'string second gap first))
                (move-point (current-point) start)
                (character-offset (current-point)
                                  (+ (length second) (length gap) offset))
                t))))))))

(defun structural-swap-backward-once ()
  (multiple-value-bind (start end) (structural-current-form-bounds)
    (when (and start end)
      (with-point ((previous-end start))
        (skip-whitespace-backward previous-end)
        (unless (or (start-buffer-p previous-end)
                    (syntax-open-paren-char-p (character-at previous-end -1)))
          (with-point ((previous-start previous-end))
            (when (form-offset previous-start -1)
              (let* ((offset (- (position-at-point (current-point))
                                (position-at-point start)))
                     (first (points-to-string previous-start previous-end))
                     (gap (points-to-string previous-end start))
                     (second (points-to-string start end)))
                (delete-between-points previous-start end)
                (insert-string previous-start
                               (concatenate 'string second gap first))
                (move-point (current-point) previous-start)
                (character-offset (current-point) offset)
                t))))))))

(define-command lem-yath-structural-drag-forward (&optional (count 1)) (:universal)
  (dotimes (_ count)
    (unless (structural-swap-forward-once) (return))))

(define-command lem-yath-structural-drag-backward (&optional (count 1)) (:universal)
  (dotimes (_ count)
    (unless (structural-swap-backward-once) (return))))

(define-command lem-yath-structural-split () ()
  "Split the containing list at point, preserving its delimiter type."
  (multiple-value-bind (start end) (structural-enclosing-list-bounds)
    (declare (ignore end))
    (when start
      (let* ((open (character-at start))
             (close (cond ((eql open #\() #\))
                          ((eql open #\[) #\])
                          ((eql open #\{) #\})
                          (t #\)))))
        (insert-string (current-point)
                       (format nil "~c~%~c" close open))
        (indent-line (current-point))))))

(define-command lem-yath-structural-join () ()
  "Join adjacent lists at a delimiter, like `lispy-join'."
  (let ((point (current-point)))
    (cond
      ((syntax-closed-paren-char-p (character-at point))
       (with-point ((next point))
         (character-offset next 1)
         (skip-whitespace-forward next)
         (when (syntax-open-paren-char-p (character-at next))
           (character-offset next 1)
           (delete-between-points point next)
           (insert-character point #\Space))))
      ((syntax-open-paren-char-p (character-at point))
       (with-point ((previous point))
         (skip-whitespace-backward previous)
         (when (syntax-closed-paren-char-p (character-at previous -1))
           (character-offset previous -1)
           (with-point ((after point))
             (character-offset after 1)
             (delete-between-points previous after)
             (insert-character previous #\Space)))))
      (t
       (call-command 'lem-vi-mode/commands:vi-join-line nil)))))

(define-command lem-yath-structural-raise-list (&optional (count 1)) (:universal)
  "Raise the current list COUNT enclosing levels."
  (dotimes (_ count)
    (multiple-value-bind (start end) (structural-enclosing-list-bounds)
      (unless start (return))
      (with-point ((parent-probe start))
        (character-offset parent-probe -1)
        (multiple-value-bind (parent-start parent-end)
            (structural-enclosing-list-bounds parent-probe)
          (unless parent-start (return))
          (let ((text (points-to-string start end)))
            (delete-between-points parent-start parent-end)
            (insert-string parent-start text)
            (move-point (current-point) parent-start)))))))

(defun structural-parent-list-bounds (child-start)
  (with-point ((probe child-start))
    (when (character-offset probe -1)
      (structural-enclosing-list-bounds probe))))

(defun structural-nth-enclosing-list-bounds (count)
  "Return the COUNTth enclosing list, where one is the current list."
  (multiple-value-bind (start end) (structural-enclosing-list-bounds)
    (loop repeat (1- count)
          while start
          do (multiple-value-setq (start end)
               (structural-parent-list-bounds start)))
    (values start end)))

(define-command lem-yath-structural-convolute () ()
  "Rotate two enclosing lists around the current list, like Lispy convolute."
  (multiple-value-bind (current-start current-end)
      (structural-enclosing-list-bounds)
    (unless current-start
      (editor-error "No current list"))
    (multiple-value-bind (parent-start parent-end)
        (structural-parent-list-bounds current-start)
      (unless parent-start
        (editor-error "Not enough depth to convolute"))
      (multiple-value-bind (outer-start outer-end)
          (structural-parent-list-bounds parent-start)
        (unless outer-start
          (editor-error "Not enough depth to convolute"))
        (with-point ((outer-content-start outer-start)
                     (outer-content-end outer-end)
                     (parent-content-start parent-start)
                     (parent-content-end parent-end))
          (character-offset outer-content-start 1)
          (character-offset outer-content-end -1)
          (character-offset parent-content-start 1)
          (character-offset parent-content-end -1)
          (let* ((offset (- (position-at-point (current-point))
                            (position-at-point current-start)))
                 (outer-prefix (points-to-string outer-content-start parent-start))
                 (outer-suffix (points-to-string parent-end outer-content-end))
                 (parent-prefix (points-to-string parent-content-start current-start))
                 (parent-suffix (points-to-string current-end parent-content-end))
                 (current (points-to-string current-start current-end))
                 (open-outer (character-at outer-start))
                 (close-outer (character-at outer-content-end))
                 (open-parent (character-at parent-start))
                 (close-parent (character-at parent-content-end))
                 (replacement
                   (format nil "~c~a~c~a~a~a~c~a~c"
                           open-parent parent-prefix
                           open-outer outer-prefix current outer-suffix close-outer
                           parent-suffix close-parent))
                 (current-new-offset
                   (+ 2 (length parent-prefix) (length outer-prefix))))
            (delete-between-points outer-start outer-end)
            (insert-string outer-start replacement)
            (move-point (current-point) outer-start)
            (character-offset (current-point) (+ current-new-offset offset))))))))

(define-command lem-yath-structural-insert-at-list-beginning
    (&optional (count 1)) (:universal)
  (multiple-value-bind (start end) (structural-nth-enclosing-list-bounds (or count 1))
    (declare (ignore end))
    (unless start (editor-error "Not enough enclosing lists"))
    (move-point (current-point) start)
    (character-offset (current-point) 1))
  (setf (lem-vi-mode/core:buffer-state) 'lem-vi-mode/states::insert))

(define-command lem-yath-structural-insert-at-list-end
    (&optional (count 1)) (:universal)
  (multiple-value-bind (start end) (structural-nth-enclosing-list-bounds (or count 1))
    (declare (ignore start))
    (unless end (editor-error "Not enough enclosing lists"))
    (move-point (current-point) end)
    (character-offset (current-point) -1))
  (setf (lem-vi-mode/core:buffer-state) 'lem-vi-mode/states::insert))

(define-command lem-yath-structural-open-below-list
    (&optional (count 1)) (:universal)
  (multiple-value-bind (start end) (structural-nth-enclosing-list-bounds (or count 1))
    (declare (ignore start))
    (unless end (editor-error "Not enough enclosing lists"))
    (move-point (current-point) end))
  (insert-character (current-point) #\Newline)
  (indent-line (current-point))
  (setf (lem-vi-mode/core:buffer-state) 'lem-vi-mode/states::insert))

(define-command lem-yath-structural-open-above-list
    (&optional (count 1)) (:universal)
  (multiple-value-bind (start end) (structural-nth-enclosing-list-bounds (or count 1))
    (declare (ignore end))
    (unless start (editor-error "Not enough enclosing lists"))
    (move-point (current-point) start))
  (insert-character (current-point) #\Newline)
  (character-offset (current-point) -1)
  (indent-line (current-point))
  (setf (lem-vi-mode/core:buffer-state) 'lem-vi-mode/states::insert))

(define-key lem-paredit-mode:*paredit-mode-keymap* "M-j"
  'lem-yath-structural-drag-forward)
(define-key lem-paredit-mode:*paredit-mode-keymap* "M-k"
  'lem-yath-structural-drag-backward)
(define-key lem-paredit-mode:*paredit-mode-keymap* "M-J"
  'lem-yath-structural-join)
(define-key lem-paredit-mode:*paredit-mode-keymap* "M-S"
  'lem-yath-structural-split)
(define-key lem-paredit-mode:*paredit-mode-keymap* "M-R"
  'lem-yath-structural-raise-list)
(define-key lem-paredit-mode:*paredit-mode-keymap* "M-v"
  'lem-yath-structural-convolute)
(define-key lem-paredit-mode:*paredit-mode-keymap* "M-i"
  'lem-yath-structural-insert-at-list-beginning)
(define-key lem-paredit-mode:*paredit-mode-keymap* "M-a"
  'lem-yath-structural-insert-at-list-end)
(define-key lem-paredit-mode:*paredit-mode-keymap* "M-o"
  'lem-yath-structural-open-below-list)
(define-key lem-paredit-mode:*paredit-mode-keymap* "M-O"
  'lem-yath-structural-open-above-list)

;;; --- atom motions (`(atom-movement t)') ----------------------------------

(defun structural-atom-context (point)
  (let ((char (character-at point)))
    (cond ((null char) nil)
          ((in-string-p point) :string)
          ((in-comment-p point) :comment)
          ((or (syntax-space-char-p char)
               (syntax-open-paren-char-p char)
               (syntax-closed-paren-char-p char))
           :separator)
          (t :atom))))

(defun structural-forward-atom-begin-once (point)
  (let ((context (structural-atom-context point)))
    (when context
      (loop while (and (not (end-buffer-p point))
                       (eq context (structural-atom-context point)))
            do (character-offset point 1)))
    (loop while (and (not (end-buffer-p point))
                     (eq :separator (structural-atom-context point)))
          do (character-offset point 1))))

(defun structural-backward-atom-begin-once (point)
  (unless (start-buffer-p point)
    (character-offset point -1)
    (loop while (and (not (start-buffer-p point))
                     (eq :separator (structural-atom-context point)))
          do (character-offset point -1))
    (let ((context (structural-atom-context point)))
      (loop while (not (start-buffer-p point))
            do (with-point ((previous point))
                 (character-offset previous -1)
                 (if (eq context (structural-atom-context previous))
                     (move-point point previous)
                     (return)))))))

(defun structural-forward-atom-end-once (point)
  (when (eq :separator (structural-atom-context point))
    (structural-forward-atom-begin-once point))
  (let ((context (structural-atom-context point)))
    (loop while (and context (not (end-buffer-p point)))
          do (with-point ((next point))
               (character-offset next 1)
               (if (eq context (structural-atom-context next))
                   (move-point point next)
                   (return))))))

(lem-vi-mode:define-motion lem-yath-structural-forward-atom-begin
    (&optional (count 1)) (:universal)
  (:type :exclusive)
  (if (structural-editing-p)
      (dotimes (_ count)
        (structural-forward-atom-begin-once (current-point)))
      (call-command 'lem-vi-mode/commands:vi-forward-word-begin-broad count)))

(lem-vi-mode:define-motion lem-yath-structural-backward-atom-begin
    (&optional (count 1)) (:universal)
  (:type :exclusive)
  (if (structural-editing-p)
      (dotimes (_ count)
        (structural-backward-atom-begin-once (current-point)))
      (call-command 'lem-vi-mode/commands:vi-backward-word-begin-broad count)))

(lem-vi-mode:define-motion lem-yath-structural-forward-atom-end
    (&optional (count 1)) (:universal)
  (:type :inclusive)
  (if (structural-editing-p)
      (dotimes (_ count)
        (structural-forward-atom-end-once (current-point))
        (unless (= _ (1- count))
          (structural-forward-atom-begin-once (current-point))))
      (call-command 'lem-vi-mode/commands:vi-forward-word-end-broad count)))

(define-key lem-vi-mode:*motion-keymap* "W"
  'lem-yath-structural-forward-atom-begin)
(define-key lem-vi-mode:*motion-keymap* "B"
  'lem-yath-structural-backward-atom-begin)
(define-key lem-vi-mode:*motion-keymap* "E"
  'lem-yath-structural-forward-atom-end)

;;; --- remaining safe normal-state commands --------------------------------

(define-command lem-yath-structural-delete-line-dispatch (argument) (:universal-nil)
  (call-command (if (structural-editing-p)
                    'lem-yath-structural-delete-to-line-end
                    'lem-yath-delete-to-line-end)
                argument))

(define-command lem-yath-structural-change-line-dispatch (argument) (:universal-nil)
  (call-command (if (structural-editing-p)
                    'lem-yath-structural-change-to-line-end
                    'lem-yath-change-to-line-end)
                argument))

(defun structural-line-comment-index (line-start line-end)
  (with-point ((p line-start))
    (loop while (point< p line-end)
          when (and (eql (character-at p) #\;)
                    (not (in-string-p p)))
            return (- (position-at-point p) (position-at-point line-start))
          do (character-offset p 1))))

(defun structural-join-next-line ()
  "Join one line while keeping Lisp code ahead of inline comments."
  (with-point ((start (current-point))
               (current-end (current-point))
               (next-start (current-point))
               (next-end (current-point)))
    (line-start start)
    (line-end current-end)
    (unless (line-offset next-start 1 0)
      (return-from structural-join-next-line nil))
    (line-start next-start)
    (move-point next-end next-start)
    (line-end next-end)
    (let* ((current-line (line-string start))
           (next-line (line-string next-start))
           (current-comment-at
             (structural-line-comment-index start current-end)))
      (if (null current-comment-at)
          (progn
            (move-point (current-point) start)
            (call-command 'lem-vi-mode/commands:vi-join-line nil))
          (let* ((next-comment-at
                   (structural-line-comment-index next-start next-end))
                 (current-code
                   (string-right-trim '(#\Space #\Tab)
                                      (subseq current-line 0 current-comment-at)))
                 (current-comment (subseq current-line current-comment-at))
                 (next-code
                   (string-trim '(#\Space #\Tab)
                                (if next-comment-at
                                    (subseq next-line 0 next-comment-at)
                                    next-line)))
                 (next-comment
                   (and next-comment-at
                        (string-left-trim '(#\Space #\Tab)
                                          (subseq next-line next-comment-at))))
                 (pieces (remove-if (lambda (s) (or (null s) (zerop (length s))))
                                    (list current-code next-code current-comment
                                          next-comment)))
                 (replacement (format nil "~{~a~^ ~}" pieces)))
            (delete-between-points start next-end)
            (insert-string start replacement)
            (move-point (current-point) start)
            t)))))

(define-command lem-yath-structural-join-line-dispatch (argument) (:universal-nil)
  (if (not (structural-editing-p))
      (call-command 'lem-vi-mode/commands:vi-join-line argument)
      (dotimes (_ (or argument 1))
        (unless (structural-join-next-line) (return)))))

(define-command lem-yath-structural-kill-last-word (argument) (:universal-nil)
  "Lispyville-safe backward word deletion in structural insert buffers."
  (if (not (structural-editing-p))
      (call-command 'lem-vi-mode/commands:vi-kill-last-word argument)
      (dotimes (_ (or argument 1))
        (with-point ((start (current-point)))
          (structural-backward-atom-begin-once start)
          (structural-safe-manipulate start (current-point) :exclusive :delete t)
          (move-point (current-point) start)))))

(define-key lem-vi-mode:*normal-keymap* "D"
  'lem-yath-structural-delete-line-dispatch)
(define-key lem-vi-mode:*normal-keymap* "C"
  'lem-yath-structural-change-line-dispatch)
(define-key lem-vi-mode:*normal-keymap* "J"
  'lem-yath-structural-join-line-dispatch)

(define-key lem-vi-mode:*normal-keymap* "x"
  'lem-yath-structural-delete-next-char)
(define-key lem-vi-mode:*normal-keymap* "X"
  'lem-yath-structural-delete-previous-char)
