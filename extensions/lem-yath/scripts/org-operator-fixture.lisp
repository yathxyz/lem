(in-package :lem-yath)

(defvar *org-operator-test-report*
  (or (uiop:getenv "LEM_YATH_ORG_OPERATOR_REPORT")
      (error "LEM_YATH_ORG_OPERATOR_REPORT is unset")))

(defvar *org-operator-test-phase*
  (or (uiop:getenv "LEM_YATH_ORG_OPERATOR_PHASE") "unknown"))

(defun org-operator-test-log (control &rest arguments)
  (with-open-file (stream *org-operator-test-report*
                          :direction :output
                          :if-does-not-exist :create
                          :if-exists :append)
    (apply #'format stream control arguments)
    (terpri stream)
    (finish-output stream)))

(defun org-operator-test-encode (string)
  (with-output-to-string (stream)
    (loop :for character :across (or string "")
          :do (case character
                (#\Newline (write-string "\\n" stream))
                (#\Return (write-string "\\r" stream))
                (#\Tab (write-string "\\t" stream))
                (#\\ (write-string "\\\\" stream))
                (otherwise (write-char character stream))))))

(defun org-operator-test-buffer-text ()
  (points-to-string (buffer-start-point (current-buffer))
                    (buffer-end-point (current-buffer))))

(defun org-operator-test-binding (keys)
  (handler-case
      (let ((command (find-keybind (lem-core::parse-keyspec keys))))
        (if (symbolp command) (symbol-name command) "NONE"))
    (error () "ERROR")))

(defun org-operator-test-binding-in-state (state keys)
  (lem-vi-mode/core:with-state state
    (org-operator-test-binding keys)))

(defun org-operator-test-route-p (state keys command)
  (string= (org-operator-test-binding-in-state state keys)
           (symbol-name command)))

(defun org-operator-test-command-p (name)
  (handler-case
      (typep (get-command name) 'lem-vi-mode/core:vi-text-object)
    (error () nil)))

(defparameter *org-operator-test-object-routes*
  '(("a e" lem-yath-org-a-object)
    ("i e" lem-yath-org-inner-object)
    ("a E" lem-yath-org-a-element)
    ("i E" lem-yath-org-inner-element)
    ("a r" lem-yath-org-a-greater-element)
    ("i r" lem-yath-org-inner-greater-element)
    ("a R" lem-yath-org-a-subtree)
    ("i R" lem-yath-org-inner-subtree)))

(defparameter *org-operator-test-motion-routes*
  '(("(" lem-yath-org-backward-sentence)
    (")" lem-yath-org-forward-sentence)
    ("{" lem-yath-org-backward-paragraph)
    ("}" lem-yath-org-forward-paragraph)
    ("g h" lem-yath-org-up-element)
    ("g l" lem-yath-org-down-element)
    ("g k" lem-yath-org-backward-element)
    ("g j" lem-yath-org-forward-element)
    ("g H" lem-yath-org-top)))

(defparameter *org-operator-test-visual-meta-routes*
  '(("M-h" lem-yath-org-visual-metaleft)
    ("M-l" lem-yath-org-visual-metaright)
    ("M-k" lem-yath-org-visual-metaup)
    ("M-j" lem-yath-org-visual-metadown)
    ("M-H" lem-yath-org-visual-shiftmetaleft)
    ("M-L" lem-yath-org-visual-shiftmetaright)
    ("M-K" lem-yath-org-visual-shiftmetaup)
    ("M-J" lem-yath-org-visual-shiftmetadown)))

(defun org-operator-test-routes-p (state)
  (loop :for (keys command) :in *org-operator-test-object-routes*
        :always (org-operator-test-route-p state keys command)))

(defun org-operator-test-motion-routes-p (state)
  (loop :for (keys command) :in *org-operator-test-motion-routes*
        :always (org-operator-test-route-p state keys command)))

(defun org-operator-test-commands-p ()
  (loop :for route :in *org-operator-test-object-routes*
        :always (org-operator-test-command-p (second route))))

(defun org-operator-test-static-report ()
  (let* ((normal 'lem-vi-mode/states:normal)
         (operator 'lem-vi-mode/states:operator)
         (visual 'lem-vi-mode/visual::visual-char)
         (normal-a (org-operator-test-binding-in-state normal "a"))
         (normal-i (org-operator-test-binding-in-state normal "i"))
         (normal-d (org-operator-test-binding-in-state normal "d"))
         (normal-x (org-operator-test-binding-in-state normal "x"))
         (normal-big-x (org-operator-test-binding-in-state normal "X"))
         (normal-left (org-operator-test-binding-in-state normal "<"))
         (normal-right (org-operator-test-binding-in-state normal ">"))
         (visual-d (org-operator-test-binding-in-state visual "d"))
         (visual-x (org-operator-test-binding-in-state visual "x"))
         (visual-left (org-operator-test-binding-in-state visual "<"))
         (visual-right (org-operator-test-binding-in-state visual ">"))
         (operator-ae (org-operator-test-binding-in-state operator "a e"))
         (operator-ie (org-operator-test-binding-in-state operator "i e"))
         (operator-ae-big (org-operator-test-binding-in-state operator "a E"))
         (operator-ie-big (org-operator-test-binding-in-state operator "i E"))
         (operator-ar (org-operator-test-binding-in-state operator "a r"))
         (operator-ir (org-operator-test-binding-in-state operator "i r"))
         (operator-ar-big (org-operator-test-binding-in-state operator "a R"))
         (operator-ir-big (org-operator-test-binding-in-state operator "i R"))
         (operator-aw (org-operator-test-binding-in-state operator "a w"))
         (operator-iw (org-operator-test-binding-in-state operator "i w"))
         (operator-left (org-operator-test-binding-in-state operator "<"))
         (operator-right (org-operator-test-binding-in-state operator ">"))
         (operator-x (org-operator-test-binding-in-state operator "x"))
         (operator-big-x (org-operator-test-binding-in-state operator "X"))
         (operator-o (org-operator-test-binding-in-state operator "o"))
         (operator-meta-l
           (org-operator-test-binding-in-state operator "M-l"))
         (normal-ok
           (and (string= normal-a "VI-APPEND")
                ;; Staged project-grep editing owns the global `i' route and
                ;; delegates to native Vi insert outside its result buffer.
                (string= normal-i "LEM-YATH-PROJECT-GREP-NORMAL-INSERT")
                (string= normal-d "LEM-YATH-ORG-DELETE-OR-SURROUND")
                (string= normal-x "LEM-YATH-ORG-DELETE-NEXT-CHAR")
                (string= normal-big-x
                         "LEM-YATH-ORG-DELETE-PREVIOUS-CHAR")
                (string= normal-left "LEM-YATH-ORG-SHIFT-LEFT")
                (string= normal-right "LEM-YATH-ORG-SHIFT-RIGHT")))
         (operator-ok
           (and (org-operator-test-routes-p operator)
                (string= operator-left "LEM-YATH-ORG-SHIFT-LEFT")
                (string= operator-right "LEM-YATH-ORG-SHIFT-RIGHT")))
         (visual-ok
           (and (org-operator-test-routes-p visual)
                (loop :for (keys command)
                        :in *org-operator-test-visual-meta-routes*
                      :always
                      (org-operator-test-route-p visual keys command))))
         (stock-ok (and (string= operator-aw "VI-A-WORD")
                        (string= operator-iw "VI-INNER-WORD")))
         (snipe-ok
           (and (string= operator-x
                         "LEM-YATH-SNIPE-OPERATOR-FORWARD-EXCLUSIVE")
                (string= operator-big-x
                         "LEM-YATH-SNIPE-OPERATOR-BACKWARD-EXCLUSIVE")))
         (safe-ok
           (and (not (string= visual-d "LEM-YATH-ORG-DELETE-OR-SURROUND"))
                (not (string= visual-x "LEM-YATH-ORG-DELETE-NEXT-CHAR"))
                (string= visual-left "LEM-YATH-ORG-SHIFT-LEFT")
                (string= visual-right "LEM-YATH-ORG-SHIFT-RIGHT")
                (not (string= operator-o "LEM-YATH-ORG-OPEN-BELOW"))
                (not (string= operator-meta-l
                              "LEM-YATH-ORG-METARIGHT"))))
         (commands-ok (org-operator-test-commands-p)))
    (org-operator-test-log
     (concatenate
      'string
      "ROUTES normal-a=~a normal-i=~a normal-d=~a normal-x=~a normal-X=~a "
      "normal-<=~a normal->=~a visual-d=~a visual-x=~a visual-<=~a visual->=~a "
      "op-ae=~a op-ie=~a "
      "op-aE=~a op-iE=~a op-ar=~a op-ir=~a op-aR=~a op-iR=~a "
      "op-aw=~a op-iw=~a op-<=~a op->=~a op-x=~a op-X=~a op-o=~a op-M-l=~a")
     normal-a normal-i normal-d normal-x normal-big-x normal-left normal-right
     visual-d visual-x visual-left visual-right
     operator-ae operator-ie operator-ae-big operator-ie-big
     operator-ar operator-ir operator-ar-big operator-ir-big operator-aw
     operator-iw operator-left operator-right operator-x operator-big-x
     operator-o operator-meta-l)
    (org-operator-test-log
     (concatenate
      'string
      "STATIC normal=~a operator=~a visual=~a stock=~a snipe=~a "
      "safe=~a commands=~a motions=~a")
     (if normal-ok "yes" "no")
     (if operator-ok "yes" "no")
     (if visual-ok "yes" "no")
     (if stock-ok "yes" "no")
     (if snipe-ok "yes" "no")
     (if safe-ok "yes" "no")
     (if commands-ok "yes" "no")
     (if (and (org-operator-test-motion-routes-p normal)
              (org-operator-test-motion-routes-p operator)
              (org-operator-test-motion-routes-p visual))
         "yes"
         "no"))))

(defun org-operator-test-state-name ()
  (let ((state (lem-vi-mode/core:current-state)))
    (cond
      ((lem-vi-mode/visual:visual-char-p) "visual-char")
      ((lem-vi-mode/visual:visual-line-p) "visual-line")
      ((lem-vi-mode/visual:visual-screen-line-p) "visual-screen-line")
      ((lem-vi-mode/visual:visual-block-p) "visual-block")
      ((typep state 'lem-vi-mode/states:operator) "operator")
      ((typep state 'lem-vi-mode/states:insert) "insert")
      ((typep state 'lem-vi-mode/states:normal) "normal")
      (t (string-downcase (symbol-name (type-of state)))))))

(defun org-operator-test-selection-kind ()
  (cond
    ((lem-vi-mode/visual:visual-char-p) "char")
    ((lem-vi-mode/visual:visual-line-p) "line")
    ((lem-vi-mode/visual:visual-screen-line-p) "screen-line")
    ((lem-vi-mode/visual:visual-block-p) "block")
    (t "none")))

(defun org-operator-test-selection-text ()
  (if (lem-vi-mode/visual:visual-p)
      (destructuring-bind (start end) (lem-vi-mode/visual:visual-range)
        (points-to-string start end))
      ""))

(defun org-operator-test-register-type-name (type)
  (if type (string-downcase (symbol-name type)) "none"))

(defun org-operator-test-state-report ()
  (multiple-value-bind (register register-type)
      (lem-vi-mode/registers:register #\")
    (multiple-value-bind (small small-type)
        (lem-vi-mode/registers:register #\-)
      (let ((text (org-operator-test-buffer-text)))
        (org-operator-test-log
         (concatenate
          'string
          "STATE phase=~a text=~a bytes=~d point=~d line=~d column=~d "
          "state=~a selection=~a selected=~a register=~a register-type=~a "
          "small=~a small-type=~a modified=~a")
         *org-operator-test-phase*
         (org-operator-test-encode text)
         (length text)
         (position-at-point (current-point))
         (line-number-at-point (current-point))
         (point-charpos (current-point))
         (org-operator-test-state-name)
         (org-operator-test-selection-kind)
         (org-operator-test-encode (org-operator-test-selection-text))
         (org-operator-test-encode (if (stringp register) register ""))
         (org-operator-test-register-type-name register-type)
         (org-operator-test-encode (if (stringp small) small ""))
         (org-operator-test-register-type-name small-type)
         (if (buffer-modified-p (current-buffer)) "yes" "no"))))))

(define-command lem-yath-test-org-operator-report () ()
  (when (string= *org-operator-test-phase* "static")
    (org-operator-test-static-report))
  (org-operator-test-state-report))

(define-key *global-keymap* "F12" 'lem-yath-test-org-operator-report)

(org-operator-test-log "READY phase=~a" *org-operator-test-phase*)
