(in-package :lem-yath)

(defvar *screen-line-fixture-report*
  (uiop:getenv "LEM_YATH_SCREEN_LINE_REPORT"))

(defvar *screen-line-fixture-last-command* nil)

(defun screen-line-fixture-track-command ()
  (setf *screen-line-fixture-last-command*
        (and (this-command) (command-name (this-command)))))

(add-hook *post-command-hook* 'screen-line-fixture-track-command)

(defun screen-line-fixture-log (control &rest arguments)
  (with-open-file (stream *screen-line-fixture-report*
                          :direction :output
                          :if-exists :append
                          :if-does-not-exist :create)
    (apply #'format stream control arguments)
    (terpri stream)))

(defun screen-line-fixture-encode (string)
  (with-output-to-string (stream)
    (loop :for character :across (or string "")
          :do (case character
                (#\Newline (write-string "\\n" stream))
                (#\Tab (write-string "\\t" stream))
                (#\\ (write-string "\\\\" stream))
                (otherwise (write-char character stream))))))

(defun screen-line-fixture-text ()
  (points-to-string (buffer-start-point (current-buffer))
                    (buffer-end-point (current-buffer))))

(defun screen-line-fixture-row-width ()
  (1- (lem-core::window-body-width (current-window))))

(defun screen-line-fixture-set-normal ()
  (when (lem-vi-mode/visual:visual-p)
    (lem-vi-mode/visual:vi-visual-end))
  (buffer-mark-cancel (current-buffer))
  (setf (lem-vi-mode/core:buffer-state)
        'lem-vi-mode/states::normal))

(defun screen-line-fixture-replace-buffer (text)
  (let ((buffer (current-buffer)))
    (buffer-disable-undo buffer)
    (erase-buffer buffer)
    (insert-string (buffer-start-point buffer) text)
    (buffer-enable-undo buffer)
    (buffer-start (current-point))
    (screen-line-fixture-set-normal)))

(define-command screen-line-fixture-prepare () ()
  "Create four predictable display rows followed by two logical lines."
  (let* ((row-width (screen-line-fixture-row-width))
         (long-line
           (concatenate 'string
                        (make-string row-width :initial-element #\A)
                        (make-string row-width :initial-element #\B)
                        (make-string row-width :initial-element #\C)
                        "DDDDDDD"))
         (text (format nil "~a~%second-short~%THIRD~%" long-line)))
    (screen-line-fixture-replace-buffer text)
    (setf (variable-value 'tab-width :buffer (current-buffer)) 4
          (variable-value 'line-wrap :buffer (current-buffer)) nil)
    (with-point ((second (current-point))
                 (third (current-point))
                 (fourth (current-point))
                 (logical-two (current-point))
                 (exact-eol (current-point))
                 (past-eol (current-point)))
      (character-offset second row-width)
      (character-offset third (* 2 row-width))
      (character-offset fourth (* 3 row-width))
      (line-offset logical-two 1)
      (move-point exact-eol logical-two)
      (move-point past-eol logical-two)
      (let ((exact-result
              (move-to-virtual-line-column
               exact-eol (length "second-short") (current-window)))
            (overflow-result
              (move-to-virtual-line-column
               past-eol (1+ (length "second-short")) (current-window))))
        (screen-line-fixture-log
         (concatenate
          'string
          "PREP width=~d row=~d first=1 second=~d third=~d fourth=~d "
          "logical2=~d baseline=~d exact=~a overflow=~a")
         (lem-core::window-body-width (current-window))
         row-width
         (position-at-point second)
         (position-at-point third)
         (position-at-point fourth)
         (position-at-point logical-two)
         (length text)
         (if exact-result "yes" "no")
         (if overflow-result "yes" "no"))))))

(defun screen-line-fixture-place (row column)
  (buffer-start (current-point))
  (when (plusp row)
    (unless (move-to-next-virtual-line
             (current-point) row (current-window))
      (editor-error "Fixture row does not exist")))
  (move-to-virtual-line-column
   (current-point) column (current-window))
  (screen-line-fixture-set-normal)
  (screen-line-fixture-log
   "SETUP row=~d column=~d point=~d"
   row column (position-at-point (current-point))))

(define-command screen-line-fixture-place-second () ()
  (screen-line-fixture-place 1 5))

(define-command screen-line-fixture-place-first () ()
  (screen-line-fixture-place 0 5))

(define-command screen-line-fixture-place-first-bol () ()
  (screen-line-fixture-place 0 0))

(define-command screen-line-fixture-prepare-widths () ()
  "Create rows that exercise CJK and tab display columns."
  (let* ((row-width (screen-line-fixture-row-width))
         (row-one
           (concatenate 'string
                        "a"
                        (make-string (1- row-width) :initial-element #\x)))
         (row-two
           (concatenate 'string
                        "界"
                        (make-string (- row-width 2) :initial-element #\y)))
         (row-three
           (concatenate 'string
                        (format nil "ab~c" #\Tab)
                        (make-string (- row-width 4) :initial-element #\z)))
         (text (concatenate 'string row-one row-two row-three "tail")))
    (screen-line-fixture-replace-buffer text)
    (setf (variable-value 'tab-width :buffer (current-buffer)) 4
          (variable-value 'line-wrap :buffer (current-buffer)) t)
    (screen-line-fixture-log
     "WIDTHS row=~d second=~d third=~d baseline=~d"
     row-width
     (+ 1 (length row-one))
     (+ 1 (length row-one) (length row-two))
     (length text))))

(define-command screen-line-fixture-prepare-structural () ()
  "Create a wrapped balanced form whose middle row begins with an opener."
  (let* ((row-width (screen-line-fixture-row-width))
         (text
           (concatenate
            'string
            (make-string row-width :initial-element #\A)
            "("
            (make-string (1- row-width) :initial-element #\B)
            (make-string (1- row-width) :initial-element #\C)
            ")tail"
            (string #\Newline))))
    (screen-line-fixture-replace-buffer text)
    (setf (variable-value 'line-wrap :buffer (current-buffer)) t)
    (screen-line-fixture-log
     "STRUCT row=~d second=~d baseline=~d"
     row-width (1+ row-width) (length text))))

(define-command screen-line-fixture-prepare-empty () ()
  "Create a non-final empty logical line and place point on it."
  (let ((text (format nil "first~%~%third~%")))
    (screen-line-fixture-replace-buffer text)
    (setf (variable-value 'line-wrap :buffer (current-buffer)) t)
    (line-offset (current-point) 1)
    (screen-line-fixture-log
     "EMPTY point=~d baseline=~d"
     (position-at-point (current-point))
     (length text))))

(define-command screen-line-fixture-prepare-word-wrap () ()
  "Create a row whose exact-width and word-boundary breaks differ."
  (let* ((row-width (screen-line-fixture-row-width))
         (prefix-length (- row-width 8))
         (word-length 12)
         (text
           (concatenate 'string
                        (make-string prefix-length :initial-element #\a)
                        " "
                        (make-string word-length :initial-element #\b)
                        (string #\Newline)
                        "tail"
                        (string #\Newline))))
    (screen-line-fixture-replace-buffer text)
    (setf (variable-value 'line-wrap :buffer (current-buffer)) t)
    (screen-line-fixture-log
     "WORD row=~d prefix=~d boundary=~d hard=~d baseline=~d"
     row-width
     prefix-length
     (+ prefix-length 2)
     (1+ row-width)
     (length text))))

(define-command screen-line-fixture-prepare-context () ()
  (let ((filename (buffer-filename (current-buffer))))
    (if (and filename
             (string-equal (or (pathname-type filename) "") "word"))
        (screen-line-fixture-prepare-word-wrap)
        (screen-line-fixture-prepare-empty))))

(define-command screen-line-fixture-prepare-empty-eof () ()
  "Create a sole empty displayed row at EOF."
  (screen-line-fixture-replace-buffer "")
  (setf (variable-value 'line-wrap :buffer (current-buffer)) t)
  (screen-line-fixture-log "EMPTYEOF baseline=0"))

(define-command screen-line-fixture-prepare-special () ()
  (if (structural-editing-p)
      (screen-line-fixture-prepare-structural)
      (screen-line-fixture-prepare-empty-eof)))

(define-command screen-line-fixture-place-width-start () ()
  (screen-line-fixture-place 0 1))

(define-command screen-line-fixture-place-width-tab () ()
  (screen-line-fixture-place 1 3))

(define-command screen-line-fixture-place-second-bol () ()
  (screen-line-fixture-place 1 0))

(defun screen-line-fixture-visual-name ()
  (cond
    ((lem-vi-mode/visual:visual-screen-line-p) "screen-line")
    ((lem-vi-mode/visual:visual-line-p) "line")
    ((lem-vi-mode/visual:visual-char-p) "char")
    ((lem-vi-mode/visual:visual-block-p) "block")
    (t "none")))

(defun screen-line-fixture-state-name ()
  (let ((state (lem-vi-mode/core:buffer-state)))
    (if state
        (lem-vi-mode/core::state-name state)
        "none")))

(defun screen-line-fixture-register (&optional (name #\"))
  (multiple-value-bind (text type)
      (lem-vi-mode/registers:register name)
    (values (or text "") (or type :none))))

(define-command screen-line-fixture-record () ()
  (let* ((point (current-point))
         (screen-start
           (lem-vi-mode/visual:screen-line-start point))
         (screen-end
           (lem-vi-mode/visual:screen-line-end point))
         (visual-range
           (and (lem-vi-mode/visual:visual-p)
                (lem-vi-mode/visual:visual-range))))
    (let* ((register
             (multiple-value-list (screen-line-fixture-register)))
           (dash
             (multiple-value-list (screen-line-fixture-register #\-)))
           (numbered
             (multiple-value-list (screen-line-fixture-register #\1)))
           (register-text (first register))
           (register-type (second register))
           (dash-text (first dash))
           (dash-type (second dash))
           (numbered-text (first numbered))
           (numbered-type (second numbered)))
      (screen-line-fixture-log
       (concatenate
        'string
        "STATE wrap=~a point=~d line=~d char=~d vcol=~d saved=~s "
        "screen=~d:~d state=~a visual=~a range=~d:~d previous=~a "
        "unnamed=~a regtype=~(~a~) reglen=~d reg=~a "
        "dashtype=~(~a~) dashlen=~d onetype=~(~a~) onelen=~d "
        "buflen=~d text=~a")
       (if (variable-value 'line-wrap :default (current-buffer)) "yes" "no")
       (position-at-point point)
       (line-number-at-point point)
       (point-charpos point)
       (point-virtual-line-column point (current-window))
       (cursor-saved-column point)
       (position-at-point screen-start)
       (position-at-point screen-end)
       (screen-line-fixture-state-name)
       (screen-line-fixture-visual-name)
       (if visual-range (position-at-point (first visual-range)) -1)
       (if visual-range (position-at-point (second visual-range)) -1)
       (or *screen-line-fixture-last-command* 'none)
       (or lem-vi-mode/registers::*unnamed-register* "none")
       register-type
       (length register-text)
       (screen-line-fixture-encode register-text)
       dash-type
       (length dash-text)
       numbered-type
       (length numbered-text)
       (length (screen-line-fixture-text))
       (screen-line-fixture-encode (screen-line-fixture-text))))))

(define-command screen-line-fixture-static () ()
  (labels ((binding (keys)
             (alexandria:when-let
                 ((prefix (lem-core::keymap-find
                           lem-vi-mode:*motion-keymap*
                           (lem-core::parse-keyspec keys))))
               (lem-core::prefix-suffix prefix))))
    (screen-line-fixture-log
     (concatenate
      'string
      "STATIC respect=~a wordwrap=~a j=~a k=~a gj=~a gk=~a zero=~a gzero=~a "
      "end=~a gend=~a visual=~a leader=~a leader-ok=~a")
     (if (variable-value
          'lem-vi-mode/visual:respect-visual-line-mode :global)
         "yes" "no")
     (if (variable-value 'line-wrap-at-word-boundary :global) "yes" "no")
     (binding "j") (binding "k") (binding "g j") (binding "g k")
     (binding "0") (binding "g 0") (binding "$") (binding "g $")
     (binding "V")
     (leader-binding-command lem-vi-mode:*normal-keymap* "y v")
     (if (evil-leader-bindings-ok-p) "yes" "no"))))

(dolist (keymap (list *global-keymap*
                      lem-vi-mode:*normal-keymap*
                      lem-vi-mode:*insert-keymap*
                      lem-vi-mode:*visual-keymap*))
  (define-key keymap "F1" 'screen-line-fixture-prepare)
  (define-key keymap "F2" 'screen-line-fixture-place-second)
  (define-key keymap "F3" 'screen-line-fixture-place-first)
  (define-key keymap "F4" 'screen-line-fixture-place-first-bol)
  (define-key keymap "F5" 'screen-line-fixture-record)
  (define-key keymap "F6" 'screen-line-fixture-static)
  (define-key keymap "F7" 'screen-line-fixture-prepare-widths)
  (define-key keymap "F8" 'screen-line-fixture-place-width-start)
  (define-key keymap "F9" 'screen-line-fixture-place-width-tab)
  (define-key keymap "F10" 'screen-line-fixture-prepare-special)
  (define-key keymap "F11" 'screen-line-fixture-place-second-bol)
  (define-key keymap "F12" 'screen-line-fixture-prepare-context))

(screen-line-fixture-log "READY")
