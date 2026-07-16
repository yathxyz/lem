(in-package :lem-yath)

(defvar *llm-conversation-test-report*
  (uiop:getenv "LEM_YATH_LLM_CONVERSATION_REPORT"))
(defvar *llm-conversation-test-last-prompt* nil)

(defun llm-conversation-test-log (control &rest arguments)
  (with-open-file (stream *llm-conversation-test-report*
                          :direction :output
                          :if-exists :append
                          :if-does-not-exist :create)
    (apply #'format stream control arguments)
    (terpri stream)))

(defun llm-conversation-test-hex (string)
  (with-output-to-string (stream)
    (loop :for character :across (or string "")
          :do (format stream "~2,'0x" (char-code character)))))

(defun llm-conversation-test-buffer-text (buffer)
  (if (llm-buffer-live-p buffer)
      (points-to-string (buffer-start-point buffer)
                        (buffer-end-point buffer))
      ""))

(defun llm-conversation-test-key-command (keymap keys)
  (alexandria:when-let
      ((prefix (lem-core::keymap-find
                keymap (lem-core::parse-keyspec keys))))
    (lem-core::prefix-suffix prefix)))

(defun llm-conversation-test-role-at (buffer text)
  (when (llm-buffer-live-p buffer)
    (with-point ((point (buffer-start-point buffer)))
      (when (search-forward point text)
        (text-property-at point 'lem-yath-llm-role -1)))))

(defmethod llm-backend-stream
    ((backend (eql :lem-yath-conversation-test)) prompt)
  (let* ((buffer (llm-output-buffer))
         (label (or (buffer-value buffer :llm-conversation-test-label)
                    "shared"))
         (insertion-point
           (llm-prepare-response
            buffer
            (format nil
                    "~%## User (conversation-test)~%~%~a~%~%## Assistant~%~%"
                    prompt)))
         (request
           (llm-register-request
            buffer nil backend :insertion-point insertion-point)))
    (setf *llm-conversation-test-last-prompt* prompt)
    (llm-conversation-test-log "SEND label=~a buffer=~a prompt-hex=~a"
                               label (buffer-name buffer)
                               (llm-conversation-test-hex prompt))
    (llm-start-request-thread
     request
     (lambda ()
       (cond
         ((string= prompt "abort")
          (llm-request-append request "partial")
          (send-event
           (lambda ()
             (llm-conversation-test-log "FIRST label=~a" label)))
          (sleep 3)
          (llm-request-append request "late")
          (llm-request-finish request (string #\Newline)))
         ((string= prompt "readonly")
          (llm-request-append request "fallback")
          (llm-request-finish request (string #\Newline))
          (send-event
           (lambda ()
             (llm-conversation-test-log "DONE label=~a" label))))
         (t
          (llm-request-append request "alpha ")
          (send-event
           (lambda ()
             (llm-conversation-test-log "FIRST label=~a" label)))
          (sleep 0.6)
          (llm-request-append request "beta")
          (llm-request-finish request (string #\Newline))
          (send-event
           (lambda ()
             (llm-conversation-test-log "DONE label=~a" label))))))
     "lem-yath/llm-conversation-test"
     (format nil "~%[test thread failed]~%"))))

(defun llm-conversation-test-setup (label text position &key read-only-p)
  (let ((buffer (or (get-buffer "*scratch*") (current-buffer))))
    (switch-to-buffer buffer)
    (setf (buffer-read-only-p buffer) nil)
    (buffer-mark-cancel buffer)
    (erase-buffer buffer)
    (unless (mode-active-p buffer 'org-mode)
      (change-buffer-mode buffer 'org-mode))
    (unless (llm-conversation-buffer-p buffer)
      (lem-yath-llm-conversation-mode t))
    (insert-string (buffer-start-point buffer) text)
    (buffer-start (buffer-point buffer))
    (character-offset (buffer-point buffer) position)
    (clear-buffer-edit-history buffer)
    (setf (buffer-value buffer :llm-conversation-test-label) label
          (buffer-read-only-p buffer) read-only-p
          *llm-backend* :lem-yath-conversation-test
          *llm-conversation-test-last-prompt* nil)
    (llm-conversation-test-log
     "SETUP label=~a text-hex=~a point=~d read-only=~a"
     label (llm-conversation-test-hex text)
     (position-at-point (buffer-point buffer))
     (if read-only-p "yes" "no"))))

(define-command lem-yath-test-llm-conversation-origin () ()
  (llm-conversation-test-setup "origin" "hello_TAIL" 5))

(define-command lem-yath-test-llm-conversation-prefix-edit () ()
  (let ((buffer (current-buffer)))
    (insert-string (buffer-start-point buffer) (format nil "PREFIX~%"))
    (llm-conversation-test-log "EDIT label=origin active=~a"
                               (if (llm-active-request buffer) "yes" "no"))))

(define-command lem-yath-test-llm-conversation-abort () ()
  (llm-conversation-test-setup "abort" "abort_TAIL" 5))

(define-command lem-yath-test-llm-conversation-read-only () ()
  (llm-conversation-test-setup "readonly" "readonly" 8 :read-only-p t))

(define-command lem-yath-test-llm-conversation-static () ()
  (let* ((buffer (current-buffer))
         (command
           (llm-conversation-test-key-command
            *lem-yath-llm-conversation-mode-keymap* "C-c Return"))
         (ok (and (string= (buffer-name buffer) "*scratch*")
                  (mode-active-p buffer 'org-mode)
                  (llm-conversation-buffer-p buffer)
                  (eq command 'lem-yath-llm-send)
                  (null (get-buffer *llm-buffer-name*)))))
    (llm-conversation-test-log
     "~a STATIC buffer=~a org=~a conversation=~a key=~a shared=~a"
     (if ok "PASS" "FAIL")
     (buffer-name buffer)
     (if (mode-active-p buffer 'org-mode) "yes" "no")
     (if (llm-conversation-buffer-p buffer) "yes" "no")
     (or command "none")
     (if (get-buffer *llm-buffer-name*) "yes" "no"))))

(define-command lem-yath-test-llm-conversation-record () ()
  (let* ((scratch (get-buffer "*scratch*"))
         (shared (get-buffer *llm-buffer-name*)))
    (llm-conversation-test-log
     (concatenate
      'string
      "STATE current=~a prompt-hex=~a scratch-hex=~a shared-hex=~a "
      "scratch-active=~a shared-active=~a assistant-role=~a user-role=~a")
     (buffer-name (current-buffer))
     (llm-conversation-test-hex *llm-conversation-test-last-prompt*)
     (llm-conversation-test-hex
      (llm-conversation-test-buffer-text scratch))
     (llm-conversation-test-hex
      (llm-conversation-test-buffer-text shared))
     (if (llm-active-request scratch) "yes" "no")
     (if (llm-active-request shared) "yes" "no")
     (or (llm-conversation-test-role-at scratch "alpha") "none")
     (or (llm-conversation-test-role-at scratch "* ") "none"))))

(dolist (keymap (list *global-keymap*
                      lem-vi-mode:*normal-keymap*
                      lem-vi-mode:*insert-keymap*
                      lem-vi-mode:*visual-keymap*))
  (define-key keymap "F2" 'lem-yath-test-llm-conversation-origin)
  (define-key keymap "F3" 'lem-yath-test-llm-conversation-static)
  (define-key keymap "F4" 'lem-yath-test-llm-conversation-prefix-edit)
  (define-key keymap "F5" 'lem-yath-test-llm-conversation-abort)
  (define-key keymap "F6" 'lem-yath-test-llm-conversation-read-only)
  (define-key keymap "F12" 'lem-yath-test-llm-conversation-record))

(setf *llm-backend* :lem-yath-conversation-test)
(llm-conversation-test-log "READY")
