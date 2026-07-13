(in-package :lem-yath)

(defvar *expreg-test-report* (uiop:getenv "LEM_YATH_EXPREG_REPORT"))
(defvar *expreg-test-record-count* 0)

(defun expreg-test-log (control &rest arguments)
  (with-open-file (stream *expreg-test-report*
                          :direction :output
                          :if-exists :append
                          :if-does-not-exist :create)
    (apply #'format stream control arguments)
    (terpri stream)))

(defun expreg-test-string-hex (string)
  (with-output-to-string (stream)
    (loop :for character :across string
          :do (format stream "~2,'0X" (char-code character)))))

(defun expreg-test-label (&optional (buffer (current-buffer)))
  (or (buffer-value buffer :expreg-test-label) "unknown"))

(defun expreg-test-open (environment label token)
  (let* ((pathname (or (uiop:getenv environment)
                       (error "Missing Expreg fixture variable ~a" environment)))
         (buffer (find-file-buffer pathname)))
    (switch-to-buffer buffer)
    (buffer-mark-cancel buffer)
    (setf (buffer-value buffer :expreg-test-label) label)
    (let ((position (search token (buffer-text buffer))))
      (unless position
        (error "Token ~s is absent from ~a" token pathname))
      (move-to-position (buffer-point buffer) (1+ position)))
    (expreg-test-log
     "OPEN label=~a language=~a mode=~a point=~d"
     label
     (or (expand-region-tree-sitter-language buffer) "fallback")
     (buffer-major-mode buffer)
     (position-at-point (buffer-point buffer)))))

(define-command lem-yath-test-expreg-open-python-expression () ()
  (expreg-test-open "LEM_YATH_EXPREG_PYTHON_EXPRESSION"
                    "python-expression" "value"))

(define-command lem-yath-test-expreg-open-python-cache-sibling () ()
  (expreg-test-open "LEM_YATH_EXPREG_PYTHON_EXPRESSION"
                    "python-cache-sibling" "bar"))

(define-command lem-yath-test-expreg-open-python-decoy () ()
  (expreg-test-open "LEM_YATH_EXPREG_PYTHON_DECOY"
                    "python-decoy" "delimiter"))

(define-command lem-yath-test-expreg-open-python-malformed () ()
  (expreg-test-open "LEM_YATH_EXPREG_PYTHON_MALFORMED"
                    "python-malformed" "beta"))

(define-command lem-yath-test-expreg-open-json () ()
  (expreg-test-open "LEM_YATH_EXPREG_JSON" "json" "café"))

(define-command lem-yath-test-expreg-open-fallback () ()
  (expreg-test-open "LEM_YATH_EXPREG_FALLBACK" "fallback" "alpha"))

(define-command lem-yath-test-expreg-record () ()
  (let* ((buffer (current-buffer))
         (visual-p (lem-vi-mode/visual:visual-p))
         (selection
           (if visual-p
               (destructuring-bind (start end)
                   (lem-vi-mode/visual:visual-range)
                 (points-to-string start end))
               "")))
    (incf *expreg-test-record-count*)
    (expreg-test-log
     "STATE index=~d label=~a language=~a visual=~a selection-hex=~a"
     *expreg-test-record-count*
     (expreg-test-label buffer)
     (or (expand-region-tree-sitter-language buffer) "fallback")
     (if visual-p "yes" "no")
     (expreg-test-string-hex selection))))

(dolist (keymap (list *global-keymap*
                      lem-vi-mode:*normal-keymap*
                      lem-vi-mode:*visual-keymap*))
  (define-key keymap "F8" 'lem-yath-test-expreg-record))

(expreg-test-log "READY")
