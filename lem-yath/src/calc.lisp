;;;; GNU Calc's everyday RPN surface, backed by bounded qalc evaluation.
;;;;
;;;; The upstream Lem contrib calculator is an algebraic line evaluator.  The
;;;; configured Emacs command is instead GNU Calc in RPN mode, with the
;;;; Evil-Collection Calc map active in Normal state.  Keep that interaction
;;;; model here and use qalc only as the mathematical evaluator; no Lisp form
;;;; supplied by the user is ever read or evaluated.

(in-package :lem-yath)

(defparameter +calc-buffer-name+ "*Calculator*")
(defconstant +calc-history-limit+ 128)
(defconstant +calc-expression-limit+ 4096)
(defconstant +calc-result-limit+ 8192)

(defvar *calc-mode-m-prefix-keymap* (make-keymap :description "Calc modes"))

(defstruct calc-session
  (stack '())
  (undo '())
  (redo '())
  (precision 12)
  (angle "deg")
  origin-buffer
  origin-window)

(define-major-mode calc-mode ()
    (:name "Calc"
     :keymap *calc-mode-keymap*)
  (setf (buffer-read-only-p (current-buffer)) t
        (variable-value 'line-wrap :buffer (current-buffer)) nil
        (variable-value 'highlight-line :buffer (current-buffer)) nil))

;; Evil-Collection starts calc-mode in Normal state and makes its major-mode
;; map take precedence over ordinary Normal motions and operators.
(defmethod lem-vi-mode/core:mode-specific-keymaps ((mode calc-mode))
  (list *calc-mode-keymap*))

(defun calc-live-buffer-p (buffer)
  (and buffer (not (deleted-buffer-p buffer))))

(defun calc-current-session (&optional (buffer (current-buffer)))
  (or (buffer-value buffer 'calc-session)
      (editor-error "This is not an active Calc buffer")))

(defun calc-stack-copy (stack)
  (copy-list stack))

(defun calc-trim-history (history)
  (if (> (length history) +calc-history-limit+)
      (subseq history 0 +calc-history-limit+)
      history))

(defun calc-stack-index-at-point ()
  (or (text-property-at (current-point) :calc-stack-index)
      0))

(defun calc-render (&optional (buffer (current-buffer)))
  "Render BUFFER's stack without making its presentation user-editable."
  (let* ((session (calc-current-session buffer))
         (stack (calc-session-stack session))
         (top-point nil))
    (with-buffer-read-only buffer nil
      (erase-buffer buffer)
      (with-point ((point (buffer-start-point buffer)))
        (loop :for value :in (reverse stack)
              :for label :downfrom (length stack)
              :for stack-index := (1- label)
              :do (let ((start (copy-point point :temporary)))
                    (insert-string point (format nil "~d:  ~a~%" label value))
                    (put-text-property start point :calc-stack-index stack-index)
                    (when (zerop stack-index)
                      (setf top-point (copy-point start :temporary)))))
        (insert-string point (format nil "    .~%")))
      (buffer-unmark buffer))
    (if top-point
        (progn
          (move-point (buffer-point buffer) top-point)
          (delete-point top-point))
        (move-point (buffer-point buffer) (buffer-start-point buffer)))
    (redraw-display)
    buffer))

(defun calc-commit-stack (session stack)
  "Commit STACK as one undoable Calc operation and refresh its buffer."
  (unless (equal stack (calc-session-stack session))
    (setf (calc-session-undo session)
          (calc-trim-history
           (cons (calc-stack-copy (calc-session-stack session))
                 (calc-session-undo session)))
          (calc-session-redo session) nil
          (calc-session-stack session) (calc-stack-copy stack)))
  (calc-render))

(defun calc-require-stack (session count)
  (when (< (length (calc-session-stack session)) count)
    (editor-error "Calc stack has fewer than ~d entr~:@p" count))
  (calc-session-stack session))

(defun calc-program ()
  (or (alexandria:when-let ((configured (uiop:getenv "LEM_YATH_QALC_PROGRAM")))
        (and (plusp (length configured))
             (uiop:probe-file* configured)))
      (executable-find "qalc")
      (editor-error "Calc requires the packaged qalc executable")))

(defun calc-normalize-result (output)
  (let* ((trimmed
           (string-trim '(#\Space #\Tab #\Newline #\Return) output))
         (one-line
           (ppcre:regex-replace-all "[\\r\\n\\t ]+" trimmed " ")))
    (when (zerop (length one-line))
      (editor-error "Calc evaluator returned no result"))
    (when (> (length one-line) +calc-result-limit+)
      (editor-error "Calc result exceeds ~d characters" +calc-result-limit+))
    one-line))

(defun calc-evaluate-expression (session expression)
  "Evaluate one bounded algebraic EXPRESSION for SESSION through qalc."
  (let ((expression
          (string-trim '(#\Space #\Tab #\Newline #\Return) expression)))
    (when (zerop (length expression))
      (editor-error "Calc entry is empty"))
    (when (> (length expression) +calc-expression-limit+)
      (editor-error "Calc expression exceeds ~d characters"
                    +calc-expression-limit+))
    (when (find #\Null expression)
      (editor-error "Calc expression contains a NUL character"))
    (let ((*project-process-timeout* 4))
      (multiple-value-bind (output error-output status)
          (run-project-program
           (list (uiop:native-namestring (calc-program))
                 "-t" "-nocurrencies" "-m" "2000"
                 "-s" (format nil "precision ~d"
                              (calc-session-precision session))
                 "-s" (format nil "angle ~a" (calc-session-angle session))
                 expression)
           :directory (uiop:getcwd)
           :output-limit 65536)
        (unless (and (integerp status) (zerop status))
          (let ((detail
                  (string-trim
                   '(#\Space #\Tab #\Newline #\Return)
                   (if (plusp (length error-output)) error-output output))))
            (editor-error "Calc could not evaluate the expression~@[: ~a~]"
                          (and (plusp (length detail))
                               (subseq detail 0 (min 240 (length detail)))))))
        (calc-normalize-result output)))))

(defun calc-read-and-push (initial &optional (prompt "Calc: "))
  "Read a prompt entry beginning with INITIAL and push its evaluated value."
  (let* ((session (calc-current-session))
         ;; Escape is deliberately handled by the configured non-Evil prompt;
         ;; evaluation and stack mutation happen only after it returns.
         (expression
           (prompt-for-string prompt
                              :initial-value initial
                              :history-symbol 'lem-yath-calc-entry))
         (result (calc-evaluate-expression session expression)))
    (calc-commit-stack session
                       (cons result (calc-session-stack session)))))

(defun calc-apply-binary (operator &optional function-form)
  (let* ((session (calc-current-session))
         (stack (calc-require-stack session 2))
         (x (first stack))
         (y (second stack))
         (expression
           (if function-form
               (format nil "~a((~a), (~a))" operator y x)
               (format nil "((~a) ~a (~a))" y operator x)))
         (result (calc-evaluate-expression session expression)))
    (calc-commit-stack session (cons result (cddr stack)))))

(defun calc-apply-unary (template)
  (let* ((session (calc-current-session))
         (stack (calc-require-stack session 1))
         (result
           (calc-evaluate-expression
            session (format nil template (first stack)))))
    (calc-commit-stack session (cons result (rest stack)))))

(defun calc-set-angle (angle label)
  (let ((session (calc-current-session)))
    (setf (calc-session-angle session) angle)
    (message "Angular mode is now ~a" label)))

(defun calc-buffer ()
  (let ((buffer (make-buffer +calc-buffer-name+)))
    (unless (eq (buffer-major-mode buffer) 'calc-mode)
      (change-buffer-mode buffer 'calc-mode))
    (unless (buffer-value buffer 'calc-session)
      (setf (buffer-value buffer 'calc-session) (make-calc-session)))
    buffer))

(defun calc-focus-bottom-window (buffer)
  "Display BUFFER in a compact bottom window when the current window permits."
  (let ((origin (current-window)))
    (if (> (window-height origin) 12)
        (let* ((height (max 2 (- (window-height origin) 8)))
               (windows-before (window-list)))
          (split-window-vertically origin :height height)
          (let ((window
                  (find-if (lambda (candidate)
                             (not (member candidate windows-before)))
                           (window-list))))
            (unless window
              (editor-error "Calc could not create its bottom window"))
            (setf (current-window) window)
            (switch-to-buffer buffer)
            window))
        (progn
          (switch-to-buffer buffer)
          (current-window)))))

(define-command calc () ()
  "Open or toggle the configured GNU-style RPN calculator."
  (if (eq (buffer-major-mode (current-buffer)) 'calc-mode)
      (calc-quit)
      (let* ((origin-buffer (current-buffer))
             (origin-window (current-window))
             (buffer (calc-buffer))
             (session (calc-current-session buffer))
             (visible
               (find buffer (window-list) :key #'window-buffer :test #'eq)))
        (setf (calc-session-origin-buffer session) origin-buffer
              (calc-session-origin-window session) origin-window)
        (if visible
            (setf (current-window) visible)
            (calc-focus-bottom-window buffer))
        (setf (lem-vi-mode/core:buffer-state buffer)
              (lem-vi-mode/core:ensure-state 'lem-vi-mode/states:normal))
        (calc-render buffer)
        (message "Welcome to Calc. Press ? for keys, q to quit"))))

(define-command calc-quit () ()
  (let* ((session (calc-current-session))
         (calc-window (current-window))
         (origin-window (calc-session-origin-window session))
         (origin-buffer (calc-session-origin-buffer session)))
    (cond
      ((and origin-window (not (deleted-window-p origin-window))
            (not (eq origin-window calc-window)))
       (delete-window calc-window)
       (setf (current-window) origin-window))
      ((calc-live-buffer-p origin-buffer)
       (switch-to-buffer origin-buffer))
      (t
       (switch-to-buffer (make-buffer "*scratch*"))))))

(define-command calc-algebraic-entry () ()
  (calc-read-and-push "" "Algebraic: "))

(define-command calc-digit-0 () () (calc-read-and-push "0"))
(define-command calc-digit-1 () () (calc-read-and-push "1"))
(define-command calc-digit-2 () () (calc-read-and-push "2"))
(define-command calc-digit-3 () () (calc-read-and-push "3"))
(define-command calc-digit-4 () () (calc-read-and-push "4"))
(define-command calc-digit-5 () () (calc-read-and-push "5"))
(define-command calc-digit-6 () () (calc-read-and-push "6"))
(define-command calc-digit-7 () () (calc-read-and-push "7"))
(define-command calc-digit-8 () () (calc-read-and-push "8"))
(define-command calc-digit-9 () () (calc-read-and-push "9"))
(define-command calc-digit-dot () () (calc-read-and-push "."))
(define-command calc-digit-negative () () (calc-read-and-push "-"))
(define-command calc-digit-e () () (calc-read-and-push "e"))

(define-command calc-enter () ()
  (let* ((session (calc-current-session))
         (stack (calc-require-stack session 1)))
    (calc-commit-stack session (cons (first stack) stack))))

(define-command calc-over () ()
  (let* ((session (calc-current-session))
         (stack (calc-require-stack session 2)))
    (calc-commit-stack session (cons (second stack) stack))))

(define-command calc-pop () ()
  (let* ((session (calc-current-session))
         (stack (calc-require-stack session 1)))
    (calc-commit-stack session (rest stack))))

(define-command calc-delete-entry () ()
  (let* ((session (calc-current-session))
         (stack (calc-require-stack session 1))
         (index (min (calc-stack-index-at-point) (1- (length stack)))))
    (copy-to-clipboard-with-killring (nth index stack))
    (calc-commit-stack
     session (append (subseq stack 0 index) (nthcdr (1+ index) stack)))))

(define-command calc-transpose () ()
  (let* ((session (calc-current-session))
         (stack (calc-require-stack session 2)))
    (calc-commit-stack session
                       (list* (second stack) (first stack) (cddr stack)))))

(define-command calc-roll-down () ()
  ;; With no prefix GNU Calc's Tab rolls the top two stack entries down.
  (calc-transpose))

(define-command calc-roll-up () ()
  ;; Evil-Collection's C-M-i uses GNU Calc's default three-entry roll-up.
  (let* ((session (calc-current-session))
         (stack (calc-require-stack session 3)))
    (calc-commit-stack
     session (list* (third stack) (first stack) (second stack) (cdddr stack)))))

(define-command calc-undo () ()
  (let ((session (calc-current-session)))
    (if (null (calc-session-undo session))
        (message "No further Calc undo information")
        (let ((previous (pop (calc-session-undo session))))
          (push (calc-stack-copy (calc-session-stack session))
                (calc-session-redo session))
          (setf (calc-session-stack session) previous)
          (calc-render)))))

(define-command calc-redo () ()
  (let ((session (calc-current-session)))
    (if (null (calc-session-redo session))
        (message "No further Calc redo information")
        (let ((next (pop (calc-session-redo session))))
          (push (calc-stack-copy (calc-session-stack session))
                (calc-session-undo session))
          (setf (calc-session-stack session) next)
          (calc-render)))))

(define-command calc-copy () ()
  (let* ((session (calc-current-session))
         (stack (calc-require-stack session 1))
         (index (min (calc-stack-index-at-point) (1- (length stack))))
         (value (nth index stack)))
    (copy-to-clipboard-with-killring value)
    (message "Copied Calc entry: ~a" value)))

(define-command calc-yank () ()
  (multiple-value-bind (text options)
      (lem/common/killring:peek-killring-item (current-killring) 0)
    (declare (ignore options))
    (unless (and (stringp text) (plusp (length text)))
      (editor-error "The kill ring has no Calc expression"))
    (let* ((session (calc-current-session))
           (result (calc-evaluate-expression session text)))
      (calc-commit-stack session
                         (cons result (calc-session-stack session))))))

(define-command calc-plus () () (calc-apply-binary "+"))
(define-command calc-minus () () (calc-apply-binary "-"))
(define-command calc-times () () (calc-apply-binary "*"))
(define-command calc-divide () () (calc-apply-binary "/"))
(define-command calc-power () () (calc-apply-binary "^"))
(define-command calc-mod () () (calc-apply-binary "mod" t))
(define-command calc-inverse () () (calc-apply-unary "1 / (~a)"))
(define-command calc-change-sign () () (calc-apply-unary "-(~a)"))
(define-command calc-factorial () () (calc-apply-unary "(~a)!"))
(define-command calc-abs () () (calc-apply-unary "abs(~a)"))
(define-command calc-log () () (calc-apply-unary "log10(~a)"))
(define-command calc-cos () () (calc-apply-unary "cos(~a)"))
(define-command calc-exp () () (calc-apply-unary "exp(~a)"))
(define-command calc-floor () () (calc-apply-unary "floor(~a)"))
(define-command calc-conj () () (calc-apply-unary "conj(~a)"))
(define-command calc-ln () () (calc-apply-unary "ln(~a)"))
(define-command calc-eval-num () () (calc-apply-unary "~a"))
(define-command calc-sqrt () () (calc-apply-unary "sqrt(~a)"))
(define-command calc-round () () (calc-apply-unary "round(~a)"))
(define-command calc-sin () () (calc-apply-unary "sin(~a)"))
(define-command calc-tan () () (calc-apply-unary "tan(~a)"))
(define-command calc-pi () ()
  (let* ((session (calc-current-session))
         (value (calc-evaluate-expression session "pi")))
    (calc-commit-stack session
                       (cons value (calc-session-stack session)))))

(define-command calc-precision () ()
  (let* ((session (calc-current-session))
         (precision
           (prompt-for-integer "Calc precision: "
                               :initial-value
                               (calc-session-precision session))))
    (unless (<= 3 precision 1000)
      (editor-error "Calc precision must be between 3 and 1000 digits"))
    (setf (calc-session-precision session) precision)
    (message "Calc precision is now ~d" precision)))

(define-command calc-angle-degrees () ()
  (calc-set-angle "deg" "degrees"))
(define-command calc-angle-radians () ()
  (calc-set-angle "rad" "radians"))
(define-command calc-angle-gradians () ()
  (calc-set-angle "gra" "gradians"))
(define-command calc-realign () () (calc-render))
(define-command calc-info () ()
  (let* ((session (calc-current-session))
         (stack (calc-require-stack session 1)))
    (message "Calc top: ~a  [precision ~d, angle ~a]"
             (first stack)
             (calc-session-precision session)
             (calc-session-angle session))))
(define-command calc-help () ()
  (message
   "Calc: digits/' enter; RET dup; S-RET over; DEL pop; d kill; + - * / %% ^; A B C E F J L N P Q R S T; Tab roll; u/D undo/redo; pp yank; M-k copy; m d/r/g angle; C-p precision; q quit"))

;;; Pinned GNU/Evil-Collection Calc bindings used by the configured profile.
(define-key *calc-mode-keymap* "0" 'calc-digit-0)
(define-key *calc-mode-keymap* "1" 'calc-digit-1)
(define-key *calc-mode-keymap* "2" 'calc-digit-2)
(define-key *calc-mode-keymap* "3" 'calc-digit-3)
(define-key *calc-mode-keymap* "4" 'calc-digit-4)
(define-key *calc-mode-keymap* "5" 'calc-digit-5)
(define-key *calc-mode-keymap* "6" 'calc-digit-6)
(define-key *calc-mode-keymap* "7" 'calc-digit-7)
(define-key *calc-mode-keymap* "8" 'calc-digit-8)
(define-key *calc-mode-keymap* "9" 'calc-digit-9)
(define-key *calc-mode-keymap* "." 'calc-digit-dot)
(define-key *calc-mode-keymap* "_" 'calc-digit-negative)
(define-key *calc-mode-keymap* "e" 'calc-digit-e)
(define-key *calc-mode-keymap* "'" 'calc-algebraic-entry)
(define-key *calc-mode-keymap* "\"" 'calc-algebraic-entry)
(define-key *calc-mode-keymap* "$" 'calc-algebraic-entry)
(define-key *calc-mode-keymap* "Return" 'calc-enter)
(define-key *calc-mode-keymap* "Space" 'calc-enter)
(define-key *calc-mode-keymap* "Shift-Return" 'calc-over)
(define-key *calc-mode-keymap* "C-j" 'calc-over)
(define-key *calc-mode-keymap* "Backspace" 'calc-pop)
(define-key *calc-mode-keymap* "Delete" 'calc-pop)
(define-key *calc-mode-keymap* "d" 'calc-delete-entry)
(define-key *calc-mode-keymap* "Tab" 'calc-roll-down)
(define-key *calc-mode-keymap* "C-M-i" 'calc-roll-up)
(define-key *calc-mode-keymap* "C-x C-t" 'calc-transpose)
(define-key *calc-mode-keymap* "u" 'calc-undo)
(define-key *calc-mode-keymap* "D" 'calc-redo)
(define-key *calc-mode-keymap* "M-k" 'calc-copy)
(define-key *calc-mode-keymap* "p p" 'calc-yank)
(define-key *calc-mode-keymap* "+" 'calc-plus)
(define-key *calc-mode-keymap* "-" 'calc-minus)
(define-key *calc-mode-keymap* "*" 'calc-times)
(define-key *calc-mode-keymap* "/" 'calc-divide)
(define-key *calc-mode-keymap* "%" 'calc-mod)
(define-key *calc-mode-keymap* "^" 'calc-power)
(define-key *calc-mode-keymap* "&" 'calc-inverse)
(define-key *calc-mode-keymap* "n" 'calc-change-sign)
(define-key *calc-mode-keymap* "!" 'calc-factorial)
(define-key *calc-mode-keymap* "A" 'calc-abs)
(define-key *calc-mode-keymap* "B" 'calc-log)
(define-key *calc-mode-keymap* "C" 'calc-cos)
(define-key *calc-mode-keymap* "E" 'calc-exp)
(define-key *calc-mode-keymap* "F" 'calc-floor)
(define-key *calc-mode-keymap* "J" 'calc-conj)
(define-key *calc-mode-keymap* "L" 'calc-ln)
(define-key *calc-mode-keymap* "N" 'calc-eval-num)
(define-key *calc-mode-keymap* "P" 'calc-pi)
(define-key *calc-mode-keymap* "Q" 'calc-sqrt)
(define-key *calc-mode-keymap* "R" 'calc-round)
(define-key *calc-mode-keymap* "S" 'calc-sin)
(define-key *calc-mode-keymap* "T" 'calc-tan)
(define-key *calc-mode-keymap* "C-p" 'calc-precision)
(define-key *calc-mode-keymap* "m" *calc-mode-m-prefix-keymap*)
(define-key *calc-mode-m-prefix-keymap* "d" 'calc-angle-degrees)
(define-key *calc-mode-m-prefix-keymap* "r" 'calc-angle-radians)
(define-key *calc-mode-m-prefix-keymap* "g" 'calc-angle-gradians)
(define-key *calc-mode-keymap* "o" 'calc-realign)
(define-key *calc-mode-keymap* "i" 'calc-info)
(define-key *calc-mode-keymap* "?" 'calc-help)
(define-key *calc-mode-keymap* "q" 'calc-quit)
