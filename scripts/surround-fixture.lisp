(in-package :lem-yath)

(defvar *surround-test-report*
  (uiop:getenv "LEM_YATH_SURROUND_REPORT"))

(defun surround-test-log (control &rest arguments)
  (with-open-file (stream *surround-test-report*
                          :direction :output
                          :if-exists :append
                          :if-does-not-exist :create)
    (apply #'format stream control arguments)
    (terpri stream)))

(defun surround-test-buffer-text ()
  (points-to-string (buffer-start-point (current-buffer))
                    (buffer-end-point (current-buffer))))

(defun surround-test-hex (string)
  (with-output-to-string (stream)
    (loop :for character :across string
          :do (format stream "~2,'0X" (char-code character)))))

(defun surround-test-anchor-at-point-p ()
  (alexandria:when-let ((anchor
                         (buffer-value (current-buffer)
                                       :surround-test-anchor)))
    (let ((remaining
            (points-to-string (current-point)
                              (buffer-end-point (current-buffer)))))
      (and (<= (length anchor) (length remaining))
           (string= anchor remaining :end2 (length anchor))))))

(defun surround-test-record ()
  (let* ((buffer (current-buffer))
         (point (current-point))
         (mark (cursor-mark point)))
    (surround-test-log
     (concatenate
      'string
      "RESULT label=~a text-hex=~a point=~d anchor=~a modified=~a "
      "mark=~a state=~a")
     (buffer-value buffer :surround-test-label)
     (surround-test-hex (surround-test-buffer-text))
     (position-at-point point)
     (if (surround-test-anchor-at-point-p) "yes" "no")
     (if (buffer-modified-p buffer) "yes" "no")
     (if (mark-active-p mark) "yes" "no")
     (class-name
      (class-of (lem-vi-mode/core:buffer-state buffer))))))

(defun surround-test-setup
    (label text anchor &key (point-adjust 0) protected-opener protected-range)
  (lem-vi-mode:vi-mode)
  (let* ((buffer (current-buffer))
         (offset (and anchor (search anchor text))))
    (unless (or (null anchor) offset)
      (error "Missing surround fixture anchor ~s" anchor))
    (setf (lem-vi-mode/core:buffer-state buffer) 'lem-vi-mode:normal
          (buffer-read-only-p buffer) nil)
    (buffer-mark-cancel buffer)
    (let ((lem/buffer/internal:*inhibit-read-only* t))
      (erase-buffer buffer)
      (insert-string (buffer-start-point buffer) text))
    (buffer-start (buffer-point buffer))
    (when offset
      (character-offset (buffer-point buffer) (+ offset point-adjust)))
    (alexandria:when-let ((range (or protected-range
                                     (and protected-opener '(0 . 1)))))
      (with-point ((start (buffer-start-point buffer))
                   (end (buffer-start-point buffer)))
        (character-offset start (car range))
        (character-offset end (cdr range))
        (put-text-property start end :read-only t)))
    (clear-buffer-edit-history buffer)
    (buffer-mark-saved buffer)
    (setf (buffer-value buffer :surround-test-label) label
          (buffer-value buffer :surround-test-anchor) anchor)
    (surround-test-log "SETUP label=~a point=~d"
                       label (position-at-point (buffer-point buffer)))))

(define-command lem-yath-test-surround-record () ()
  (surround-test-record))

(define-command lem-yath-test-surround-nested-inner () ()
  (surround-test-setup "nested-inner" "((alpha) omega)" "alpha"))

(define-command lem-yath-test-surround-nested-outer () ()
  (surround-test-setup "nested-outer" "((alpha) omega)" "omega"))

(define-command lem-yath-test-surround-string-decoy () ()
  (surround-test-setup
   "string-decoy" "(alpha, \")\", omega)" "alpha"))

(define-command lem-yath-test-surround-string-target () ()
  (surround-test-setup
   "string-target" "(call \"alpha\")" "alpha"))

(define-command lem-yath-test-surround-mixed-delimiters () ()
  (surround-test-setup
   "mixed-delimiters" "{[alpha]}" "alpha"))

(define-command lem-yath-test-surround-comment-decoy () ()
  (surround-test-setup
   "comment-decoy"
   (format nil "(~%  alpha~%  # ) decoy~%  omega~%)~%")
   "alpha"))

(define-command lem-yath-test-surround-escaped-quote () ()
  (surround-test-setup
   "escaped-quote"
   (concatenate 'string "\"alpha " (string #\\) "\" beta\"")
   "beta"))

(define-command lem-yath-test-surround-triple-quote () ()
  (surround-test-setup
   "triple-quote" "\"\"\"alpha\"\"\"" "\""))

(define-command lem-yath-test-surround-triple-quote-second () ()
  (surround-test-setup
   "triple-quote-second" "\"\"\"alpha\"\"\"" "\"" :point-adjust 1))

(define-command lem-yath-test-surround-triple-quote-body () ()
  (surround-test-setup
   "triple-quote-body" "\"\"\"alpha\"\"\"" "alpha"))

(define-command lem-yath-test-surround-padded-change () ()
  (surround-test-setup "padded-change" "( alpha )" "alpha"))

(define-command lem-yath-test-surround-compact-change () ()
  (surround-test-setup "compact-change" "[alpha]" "alpha"))

(define-command lem-yath-test-surround-single-padding () ()
  (surround-test-setup "single-padding" "( )" nil))

(define-command lem-yath-test-surround-malformed () ()
  (surround-test-setup "malformed" "(alpha" "alpha"))

(define-command lem-yath-test-surround-protected () ()
  (surround-test-setup
   "protected" "(alpha)" "alpha" :protected-opener t))

(define-command lem-yath-test-surround-protected-inner () ()
  (surround-test-setup
   "protected-inner" "(alpha)" "alpha" :protected-range '(1 . 2)))

(define-command lem-yath-test-surround-protected-suffix () ()
  (surround-test-setup
   "protected-suffix" "(alpha)Z" "alpha" :protected-range '(7 . 8)))

(define-command lem-yath-test-surround-lisp-character-literals () ()
  (change-buffer-mode (current-buffer) 'lem-lisp-mode:lisp-mode)
  (surround-test-setup
   "lisp-character-literals"
   "(list #\\( alpha #\\) tail)"
   "alpha"))

(define-command lem-yath-test-surround-lisp-fence-decoy () ()
  (surround-test-setup
   "lisp-fence-decoy" "(list |foo(bar| alpha)" "alpha"))

(define-command lem-yath-test-surround-lisp-fence-delete () ()
  (surround-test-setup
   "lisp-fence-delete" "(|foo bar|)" "foo"))

;; The fixture loads before its command-line Python file, so suppress only the
;; unrelated server startup in this isolated editor process.
(ignore-errors
  (remove-hook lem-python-mode:*python-mode-hook*
               'lem-lsp-mode::enable-lsp-mode))

(dolist (keymap (list *global-keymap*
                      lem-vi-mode:*normal-keymap*))
  (define-key keymap "F12" 'lem-yath-test-surround-record))

(surround-test-log "READY")
