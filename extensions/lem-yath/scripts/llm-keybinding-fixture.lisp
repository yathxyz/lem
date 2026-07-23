(in-package :lem-yath)

(defvar *llm-keybinding-report*
  (uiop:getenv "LEM_YATH_LLM_KEYBINDING_REPORT"))
(defvar *llm-keybinding-call-count* 0)
(defvar *llm-keybinding-last-prompt* nil)

(defun llm-keybinding-log (control &rest arguments)
  (with-open-file (stream *llm-keybinding-report*
                          :direction :output
                          :if-exists :append
                          :if-does-not-exist :create)
    (apply #'format stream control arguments)
    (terpri stream)))

(defun llm-keybinding-hex (string)
  (with-output-to-string (stream)
    (loop :for character :across (or string "")
          :do (format stream "~2,'0x" (char-code character)))))

(defun llm-keybinding-buffer-text ()
  (points-to-string (buffer-start-point (current-buffer))
                    (buffer-end-point (current-buffer))))

(defun llm-keybinding-vi-state-name ()
  (let ((state (lem-vi-mode/core:current-state)))
    (cond
      ((typep state 'lem-vi-mode:insert) "insert")
      ((typep state 'lem-vi-mode:normal) "normal")
      ((typep state 'lem-vi-mode:visual) "visual")
      (t "other"))))

(defun llm-keybinding-key-command (keymap keys)
  (alexandria:when-let
      ((prefix (lem-core::keymap-find
                keymap
                (lem-core::parse-keyspec keys))))
    (lem-core::prefix-suffix prefix)))

(defmethod llm-backend-stream ((backend (eql :lem-yath-keybinding-test))
                               prompt)
  (incf *llm-keybinding-call-count*)
  (setf *llm-keybinding-last-prompt* prompt)
  (llm-keybinding-log "SEND call=~d prompt-hex=~a vi=~a"
                      *llm-keybinding-call-count*
                      (llm-keybinding-hex prompt)
                      (llm-keybinding-vi-state-name)))

(defun llm-keybinding-setup
    (label point-position &optional mark-position
                            (text (format nil "  prefix prompt suffix~%")))
  (let ((buffer (current-buffer)))
    (setf (buffer-read-only-p buffer) nil)
    (buffer-mark-cancel buffer)
    (erase-buffer buffer)
    (insert-string (buffer-start-point buffer) text)
    (buffer-start (buffer-point buffer))
    (character-offset (buffer-point buffer) point-position)
    (when mark-position
      (with-point ((mark (buffer-start-point buffer)))
        (character-offset mark mark-position)
        (setf (buffer-mark buffer) mark)))
    (clear-buffer-edit-history buffer)
    (setf (buffer-value buffer :llm-keybinding-label) label
          *llm-keybinding-call-count* 0
          *llm-keybinding-last-prompt* nil
          *llm-backend* :lem-yath-keybinding-test)
    (llm-keybinding-log "SETUP label=~a point=~d mark=~a vi=~a"
                        label
                        (position-at-point (current-point))
                        (if (buffer-mark-p buffer) "yes" "no")
                        (llm-keybinding-vi-state-name))))

(define-command lem-yath-test-llm-up-to-point () ()
  (llm-keybinding-setup "up-to-point" 15))

(define-command lem-yath-test-llm-forward-region () ()
  (llm-keybinding-setup "forward-region" 9 14))

(define-command lem-yath-test-llm-reverse-region () ()
  (llm-keybinding-setup "reverse-region" 14 9))

(define-command lem-yath-test-llm-mid-word () ()
  (llm-keybinding-setup "mid-word" 11))

(define-command lem-yath-test-llm-blank () ()
  (llm-keybinding-setup "blank" 4 nil
                        (format nil "  ~c~%" #\Tab)))

(define-command lem-yath-test-llm-mid-punctuation () ()
  (llm-keybinding-setup "mid-punctuation" 7 nil
                        (format nil "prefix... suffix~%")))

(define-command lem-yath-test-llm-symbol-stop () ()
  (llm-keybinding-setup "symbol-stop" 2 nil
                        (format nil "alpha_beta suffix~%")))

(define-command lem-yath-test-llm-static () ()
  (let ((insert-command
          (llm-keybinding-key-command
           lem-vi-mode:*insert-keymap* "C-c i"))
        (visual-command
          (llm-keybinding-key-command
           lem-vi-mode:*visual-keymap* "C-c i")))
    (llm-keybinding-log "~a STATIC C-c-i insert=~a visual=~a"
                        (if (and (eq insert-command 'lem-yath-llm-send)
                                 (eq visual-command 'lem-yath-llm-send))
                            "PASS"
                            "FAIL")
                        (or insert-command "none")
                        (or visual-command "none"))))

(define-command lem-yath-test-llm-record () ()
  (let ((buffer (current-buffer)))
    (llm-keybinding-log
     "STATE label=~a calls=~d prompt-hex=~a text-hex=~a point=~d mark=~a vi=~a"
     (or (buffer-value buffer :llm-keybinding-label) "none")
     *llm-keybinding-call-count*
     (llm-keybinding-hex *llm-keybinding-last-prompt*)
     (llm-keybinding-hex (llm-keybinding-buffer-text))
     (position-at-point (current-point))
     (if (buffer-mark-p buffer) "yes" "no")
     (llm-keybinding-vi-state-name))))

(dolist (keymap (list *global-keymap*
                      lem-vi-mode:*normal-keymap*
                      lem-vi-mode:*insert-keymap*
                      lem-vi-mode:*visual-keymap*))
  (define-key keymap "F5" 'lem-yath-test-llm-up-to-point)
  (define-key keymap "F4" 'lem-yath-test-llm-symbol-stop)
  (define-key keymap "F6" 'lem-yath-test-llm-forward-region)
  (define-key keymap "F7" 'lem-yath-test-llm-reverse-region)
  (define-key keymap "F8" 'lem-yath-test-llm-static)
  (define-key keymap "F9" 'lem-yath-test-llm-mid-word)
  (define-key keymap "F10" 'lem-yath-test-llm-blank)
  (define-key keymap "F11" 'lem-yath-test-llm-mid-punctuation)
  (define-key keymap "F12" 'lem-yath-test-llm-record))

(setf *llm-backend* :lem-yath-keybinding-test)
(llm-keybinding-log "READY")
