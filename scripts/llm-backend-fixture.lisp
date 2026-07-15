(in-package :lem-yath)

(defvar *llm-backend-test-report*
  (uiop:getenv "LEM_YATH_LLM_BACKEND_REPORT"))

(let ((directory (uiop:ensure-directory-pathname
                  (uiop:getenv "LEM_YATH_LLM_FAKE_BIN"))))
  (setf *llm-curl-executable* (namestring (merge-pathnames "curl" directory))
        *llm-cli-commands*
        `((:claude-code . ,(namestring (merge-pathnames "claude" directory)))
          (:codex . ,(namestring (merge-pathnames "codex" directory)))
          (:grok . ,(namestring (merge-pathnames "grok" directory))))))

(defun llm-backend-test-log (control &rest arguments)
  (with-open-file (stream *llm-backend-test-report*
                          :direction :output
                          :if-exists :append
                          :if-does-not-exist :create)
    (apply #'format stream control arguments)
    (terpri stream)))

(defun llm-backend-test-text ()
  (let ((buffer (llm-output-buffer)))
    (points-to-string (buffer-start-point buffer)
                      (buffer-end-point buffer))))

(defun llm-backend-test-contains-p (needle)
  (not (null (search needle (llm-backend-test-text)))))

(defun llm-backend-test-argv (argv)
  (format nil "~{~a~^|~}" argv))

(define-command lem-yath-test-llm-backend-static () ()
  (let ((failures 0))
    (labels ((check (condition name)
               (llm-backend-test-log "~a STATIC ~a"
                                     (if condition "PASS" "FAIL") name)
               (unless condition (incf failures))))
      (check
       (equal
        (llm-cli-command :claude-code "hello" "claude-session-1")
        (list (llm-cli-spec :claude-code) "-p" "hello"
              "--output-format" "stream-json"
              "--verbose" "--resume" "claude-session-1"
              "--append-system-prompt" *llm-system-message*))
       "claude-native-resume-argv")
      (check
       (equal
        (llm-cli-command :codex "hello" "codex-thread-1")
        (list (llm-cli-spec :codex) "exec" "resume" "codex-thread-1" "--json"
              "-s" "read-only" (llm-cli-compose-prompt "hello")))
       "codex-native-resume-argv")
      (check
       (equal
        (llm-cli-command :grok "hello" "grok-session-1")
        (list (llm-cli-spec :grok) "-p" (llm-cli-compose-prompt "hello")
              "--output-format" "streaming-json" "-r" "grok-session-1"
              "-m" "grok-build" "--sandbox" "read-only"
              "--permission-mode" "dontAsk" "--disable-web-search"
              "--no-subagents" "--no-plan"))
       "grok-native-resume-argv")
      (check (not (llm-cli-session-id-valid-p "--danger"))
             "reject-option-shaped-session")
      (check (not (llm-cli-session-id-valid-p (format nil "line~%break")))
             "reject-control-session")
      (check (null (llm-cli-parse-event
                    :codex (make-string (1+ *llm-cli-line-limit*)
                                        :initial-element #\x)))
             "bound-event-line")
      (check (null (llm-cli-parse-event :claude-code "{bad"))
             "ignore-malformed-event")
      (check (and (eq 'lem-yath-llm-new-session
                      (leader-binding-command
                       lem-vi-mode:*normal-keymap* "g n"))
                  (eq 'lem-yath-llm-new-session
                      (leader-binding-command
                       lem-vi-mode:*visual-keymap* "g n")))
             "new-session-leader-both-states")
      (check (and (eq 'lem-yath-llm-abort
                      (leader-binding-command
                       lem-vi-mode:*normal-keymap* "g a"))
                  (eq 'lem-yath-llm-abort
                      (leader-binding-command
                       lem-vi-mode:*visual-keymap* "g a")))
             "abort-leader-both-states")
      (llm-backend-test-log "SUMMARY STATIC ~a failures=~d"
                            (if (zerop failures) "PASS" "FAIL") failures))))

(defun llm-backend-test-send (backend prompt)
  (setf *llm-backend* backend)
  (llm-backend-stream backend prompt)
  (llm-backend-test-log "SEND backend=~a prompt=~a" backend prompt))

(define-command lem-yath-test-llm-openrouter () ()
  (llm-backend-test-send :openrouter "openrouter prompt"))

(define-command lem-yath-test-llm-claude () ()
  (llm-backend-test-send :claude-code "claude prompt"))

(define-command lem-yath-test-llm-codex () ()
  (llm-backend-test-send :codex "codex prompt"))

(define-command lem-yath-test-llm-grok () ()
  (llm-backend-test-send :grok "grok prompt"))

(define-command lem-yath-test-llm-slow-claude () ()
  (llm-backend-test-send :claude-code "abort prompt"))

(define-command lem-yath-test-llm-abort () ()
  (llm-backend-test-log "ABORT begin")
  (lem-yath-llm-abort)
  (llm-backend-test-log "ABORT end"))

(define-command lem-yath-test-llm-new-session () ()
  (setf *llm-backend* :claude-code)
  (lem-yath-llm-new-session)
  (llm-backend-test-log "NEW claude=~a"
                        (or (llm-cli-session-id :claude-code) "none")))

(define-command lem-yath-test-llm-backend-record () ()
  (let ((buffer (llm-output-buffer)))
    (llm-backend-test-log
     (concatenate
      'string
      "STATE active=~a openrouter=~a claude1=~a claude2=~a claude3=~a "
      "thinking=~a tool=~a tool-result=~a codex1=~a codex2=~a "
      "command=~a file=~a grok1=~a grok2=~a aborted=~a "
      "claude-id=~a codex-id=~a grok-id=~a")
     (if (llm-active-request buffer) "yes" "no")
     (if (llm-backend-test-contains-p "OpenRouter") "yes" "no")
     (if (llm-backend-test-contains-p "Claude answer 1") "yes" "no")
     (if (llm-backend-test-contains-p "Claude answer 2") "yes" "no")
     (if (llm-backend-test-contains-p "Claude answer 3") "yes" "no")
     (if (llm-backend-test-contains-p "checked context") "yes" "no")
     (if (llm-backend-test-contains-p "Claude tool: `Read`") "yes" "no")
     (if (llm-backend-test-contains-p "Claude tool result") "yes" "no")
     (if (llm-backend-test-contains-p "Codex answer 1") "yes" "no")
     (if (llm-backend-test-contains-p "Codex answer 2") "yes" "no")
     (if (llm-backend-test-contains-p "[Codex command completed; exit 0] pwd")
         "yes" "no")
     (if (llm-backend-test-contains-p "- update safe.lisp") "yes" "no")
     (if (llm-backend-test-contains-p "Grok answer 1") "yes" "no")
     (if (llm-backend-test-contains-p "Grok answer 2") "yes" "no")
     (if (llm-backend-test-contains-p "[request aborted]") "yes" "no")
     (or (llm-cli-session-id :claude-code buffer) "none")
     (or (llm-cli-session-id :codex buffer) "none")
     (or (llm-cli-session-id :grok buffer) "none"))))

(dolist (keymap (list *global-keymap*
                      lem-vi-mode:*normal-keymap*
                      lem-vi-mode:*insert-keymap*
                      lem-vi-mode:*visual-keymap*))
  (define-key keymap "F2" 'lem-yath-test-llm-backend-static)
  (define-key keymap "F3" 'lem-yath-test-llm-openrouter)
  (define-key keymap "F4" 'lem-yath-test-llm-claude)
  (define-key keymap "F5" 'lem-yath-test-llm-codex)
  (define-key keymap "F6" 'lem-yath-test-llm-grok)
  (define-key keymap "F7" 'lem-yath-test-llm-abort)
  (define-key keymap "F8" 'lem-yath-test-llm-slow-claude)
  (define-key keymap "F9" 'lem-yath-test-llm-new-session)
  (define-key keymap "F12" 'lem-yath-test-llm-backend-record))

(llm-backend-test-log "READY")
