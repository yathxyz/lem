(in-package :lem-yath)

(defvar *claude-code-test-report*
  (uiop:getenv "LEM_YATH_CLAUDE_CODE_REPORT"))

(setf *claude-code-command-candidates*
      (list (list (uiop:getenv "LEM_YATH_CLAUDE_CODE_FAKE") "code")
            (list "claude")))

(defun claude-code-test-log (control &rest arguments)
  (with-open-file (stream *claude-code-test-report*
                          :direction :output
                          :if-exists :append
                          :if-does-not-exist :create)
    (apply #'format stream control arguments)
    (terpri stream)))

(defun claude-code-test-key-command (keymap keys)
  (alexandria:when-let
      ((prefix (lem-core::keymap-find
                keymap
                (lem-core::parse-keyspec keys))))
    (lem-core::prefix-suffix prefix)))

(defun claude-code-test-buffer-text (buffer)
  (points-to-string (buffer-start-point buffer) (buffer-end-point buffer)))

(define-command lem-yath-test-claude-code-static () ()
  (let* ((binding (claude-code-test-key-command
                   lem-vi-mode:*normal-keymap* "C-c c"))
         (resolved (claude-code-resolve-command)))
    (claude-code-test-log
     "STATIC binding=~a resolved=~a suffix=~a"
     binding
     (and resolved (first resolved))
     (and resolved (second resolved)))))

(define-command lem-yath-test-claude-code-record () ()
  (let* ((session (lem/interactive-mode::session (current-buffer)))
         (context (and session
                       (lem/interactive-mode:session-context session)))
         (output (and session
                      (lem/interactive-mode::session-output-buffer session)))
         (text (and output (claude-code-test-buffer-text output)))
         (events (and context
                      (reverse
                       (copy-list
                        (lem-claude-code::context-output-log context))))))
    (claude-code-test-log
     (concatenate
      'string
      "STATE session=~a directory=~a command=~{~a~^|~} events=~d "
      "types=~{~a~^,~} first=~a second=~a tool=~a")
     (and session (lem-claude-code::session-id session))
     (and context
          (uiop:native-namestring
           (lem-yath-claude-code-directory context)))
     (and context (lem-yath-claude-code-command context))
     (length events)
     (mapcar (lambda (event) (gethash "type" event)) events)
     (if (and text (search "FIRST-CLAUDE-REPLY" text)) "yes" "no")
     (if (and text (search "SECOND-CLAUDE-REPLY" text)) "yes" "no")
     (if (and text (search "Read" text)) "yes" "no"))))

(dolist (keymap (list *global-keymap*
                      lem-vi-mode:*normal-keymap*
                      lem-vi-mode:*insert-keymap*
                      lem-vi-mode:*visual-keymap*))
  (define-key keymap "F2" 'lem-yath-test-claude-code-static)
  (define-key keymap "F12" 'lem-yath-test-claude-code-record))

(claude-code-test-log "READY")
