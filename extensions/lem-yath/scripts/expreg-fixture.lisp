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

(define-command lem-yath-test-expreg-open-python-arbitrary () ()
  (expreg-test-open "LEM_YATH_EXPREG_PYTHON_EXPRESSION"
                    "python-arbitrary" "value"))

(define-command lem-yath-test-expreg-open-python-decoy () ()
  (expreg-test-open "LEM_YATH_EXPREG_PYTHON_DECOY"
                    "python-decoy" "delimiter"))

(define-command lem-yath-test-expreg-open-python-escaped-list () ()
  (expreg-test-open "LEM_YATH_EXPREG_PYTHON_DECOY"
                    "python-escaped-list" "escaped_token"))

(define-command lem-yath-test-expreg-open-python-block-string () ()
  (expreg-test-open "LEM_YATH_EXPREG_PYTHON_DECOY"
                    "python-block-string" "block_item"))

(define-command lem-yath-test-expreg-open-python-malformed () ()
  (expreg-test-open "LEM_YATH_EXPREG_PYTHON_MALFORMED"
                    "python-malformed" "beta"))

(define-command lem-yath-test-expreg-open-python-malformed-nested () ()
  (expreg-test-open "LEM_YATH_EXPREG_PYTHON_MALFORMED_NESTED"
                    "python-malformed-nested" "beta"))

(define-command lem-yath-test-expreg-open-json () ()
  (expreg-test-open "LEM_YATH_EXPREG_JSON" "json" "café"))

(define-command lem-yath-test-expreg-open-json-string-list () ()
  (expreg-test-open "LEM_YATH_EXPREG_JSON_STRING"
                    "json-string-list" "item"))

(define-command lem-yath-test-expreg-open-rust () ()
  (expreg-test-open "LEM_YATH_EXPREG_RUST" "rust" "value"))

(define-command lem-yath-test-expreg-open-fallback () ()
  (expreg-test-open "LEM_YATH_EXPREG_FALLBACK" "fallback" "alpha"))

(define-command lem-yath-test-expreg-record () ()
  (let* ((buffer (current-buffer))
         (visual-p (lem-vi-mode/visual:visual-p))
         (range
           (when visual-p
             (lem-vi-mode/visual:visual-range)))
         (selection
           (if range
               (points-to-string (first range) (second range))
               "")))
    (incf *expreg-test-record-count*)
    (expreg-test-log
     "STATE index=~d label=~a language=~a visual=~a point=~d start=~d end=~d selection-hex=~a"
     *expreg-test-record-count*
     (expreg-test-label buffer)
     (or (expand-region-tree-sitter-language buffer) "fallback")
     (if visual-p "yes" "no")
     (position-at-point (current-point))
     (if range (position-at-point (first range)) -1)
     (if range (position-at-point (second range)) -1)
     (expreg-test-string-hex selection))))

(define-command lem-yath-test-expreg-stale-contract () ()
  (alexandria:when-let
      ((session
         (buffer-value
          (current-buffer) 'lem-yath-expand-region-session)))
    (setf (expand-region-session-tick session)
          (1- (expand-region-session-tick session))))
  (expreg-contract)
  (destructuring-bind (start end) (lem-vi-mode/visual:visual-range)
    (expreg-test-log
     "STALE visual=~a selection-hex=~a"
     (if (lem-vi-mode/visual:visual-p) "yes" "no")
     (expreg-test-string-hex (points-to-string start end)))))

(dolist (keymap (list *global-keymap*
                      lem-vi-mode:*normal-keymap*
                      lem-vi-mode:*visual-keymap*))
  (define-key keymap "F6" 'lem-yath-test-expreg-stale-contract)
  (define-key keymap "F7" 'expreg-contract)
  (define-key keymap "F8" 'lem-yath-test-expreg-record))

(expreg-test-log "COMMAND contract=~a"
                 (if (find-command "expreg-contract") "yes" "no"))
(expreg-test-log "READY")
