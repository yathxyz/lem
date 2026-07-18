(in-package :lem-yath)

(defvar *llm-backend-test-report*
  (uiop:getenv "LEM_YATH_LLM_BACKEND_REPORT"))
(defvar *llm-backend-test-claude-message-id* nil)
(defvar *llm-backend-test-claude-session-id* nil)

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

(defun llm-backend-test-finish-metadata (request reason)
  (declare (ignore reason))
  (when (eq (llm-request-backend request) :claude-code)
    (setf *llm-backend-test-claude-message-id*
          (llm-request-provider-message-id request)
          *llm-backend-test-claude-session-id*
          (llm-request-provider-session-id request))))

(define-command lem-yath-test-llm-backend-static () ()
  (let ((failures 0))
    (labels ((check (condition name)
               (llm-backend-test-log "~a STATIC ~a"
                                     (if condition "PASS" "FAIL") name)
               (unless condition (incf failures))))
      (check
       (equal
        (llm-cli-command
         :claude-code "hello" "claude-session-1"
         #P"/safe/project/.mcp.json")
        (list (llm-cli-spec :claude-code) "-p" "hello"
              "--output-format" "stream-json"
              "--verbose" "--resume" "claude-session-1"
              "--allowedTools" "Bash"
              "--allowedTools" "Read"
              "--allowedTools" "Edit"
              "--allowedTools" "Write"
              "--allowedTools" "Glob"
              "--allowedTools" "Grep"
              "--allowedTools" "WebFetch"
              "--allowedTools" "WebSearch"
              "--allowedTools" "Agent"
              "--append-system-prompt" *llm-system-message*
              "--mcp-config" "/safe/project/.mcp.json"))
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
      (let ((buffer (make-buffer " *Claude Unsafe Root Static*")))
        (unwind-protect
             (progn
               (setf (buffer-directory buffer) (user-homedir-pathname))
               (check
                (handler-case
                    (progn (llm-claude-project-root buffer) nil)
                  (editor-error () t))
                "reject-home-as-claude-root"))
          (delete-buffer buffer)))
      (let* ((project-root
               (uiop:ensure-directory-pathname
                (uiop:getenv "LEM_YATH_LLM_CLAUDE_PROJECT_ROOT")))
             (project-config (merge-pathnames ".mcp.json" project-root))
             (home-config
               (merge-pathnames ".claude/.mcp.json"
                                (user-homedir-pathname)))
             (symlink-config
               (merge-pathnames ".claude/symlink-mcp.json"
                                (user-homedir-pathname))))
        (check
         (uiop:pathname-equal
          (llm-claude-mcp-config-pathname project-root)
          project-config)
         "prefer-project-mcp-config")
        (check (not (llm-claude-safe-owned-file-p symlink-config))
               "reject-symlink-mcp-config")
        #+sbcl
        (unwind-protect
             (progn
               (sb-posix:chmod (uiop:native-namestring project-config) #o666)
               (check
                (uiop:pathname-equal
                 (llm-claude-mcp-config-pathname project-root)
                 home-config)
                "fallback-to-home-mcp-config"))
          (sb-posix:chmod (uiop:native-namestring project-config) #o600)))
      (check (null (llm-cli-parse-event
                    :codex (make-string (1+ *llm-cli-line-limit*)
                                        :initial-element #\x)))
             "bound-event-line")
      (check (null (llm-cli-parse-event :claude-code "{bad"))
             "ignore-malformed-event")
      (check
       (equal
        (getf (llm-cli-parse-event
               :claude-code
               "{\"type\":\"result\",\"session_id\":\"safe\",\"uuid\":\"boundary\"}")
              :message-id)
        "boundary")
       "capture-claude-message-boundary")
      (let* ((request
               (make-llm-request nil nil :claude-code
                                 :provider-session-id "safe-session"
                                 :provider-message-id "safe-boundary"))
             (state (llm-response-state-for-request request)))
        (check (and (equal (llm-response-state-provider-session-id state)
                           "safe-session")
                    (equal (llm-response-state-provider-message-id state)
                           "safe-boundary"))
               "attach-provider-metadata-to-response-state"))
      (check (and (eq 'lem-yath-llm-claude-fork
                      (lem-core::prefix-suffix
                       (lem-core::keymap-find
                        *lem-yath-llm-conversation-mode-keymap*
                        (lem-core::parse-keyspec "C-c C-f"))))
                  (eq 'lem-yath-llm-claude-browse-sessions
                      (lem-core::prefix-suffix
                       (lem-core::keymap-find
                        *lem-yath-llm-conversation-mode-keymap*
                        (lem-core::parse-keyspec "C-c C-b")))))
             "claude-conversation-bindings")
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

(define-command lem-yath-test-llm-claude-session-setup () ()
  (let ((buffer (make-buffer "*Claude Session Test*")))
    (switch-to-buffer buffer)
    (setf (buffer-read-only-p buffer) nil
          (buffer-directory buffer)
          (uiop:ensure-directory-pathname
           (uiop:getenv "LEM_YATH_LLM_CLAUDE_PROJECT_ROOT")))
    (buffer-mark-cancel buffer)
    (erase-buffer buffer)
    (unless (mode-active-p buffer 'org-mode)
      (change-buffer-mode buffer 'org-mode))
    (unless (llm-conversation-buffer-p buffer)
      (lem-yath-llm-conversation-mode t))
    (insert-string (buffer-end-point buffer) (format nil "* Prompt~2%")
                   'lem-yath-llm-role :user)
    (insert-string
     (buffer-end-point buffer) "Claude boundary response"
     'lem-yath-llm-role :assistant
     *llm-response-state-key*
     (make-llm-response-state
      :backend :claude-code
      :model "claude-code"
      :system-message "test"
      :provider-session-id "claude-session-1"
      :provider-message-id "claude-message-boundary"))
    (insert-string (buffer-end-point buffer) (format nil "~2%* Follow-up")
                   'lem-yath-llm-role :user)
    (buffer-end (buffer-point buffer))
    (clear-buffer-edit-history buffer)
    (llm-cli-store-session-id buffer :claude-code "claude-session-1")
    (llm-role-refresh-static-overlays buffer)
    (llm-backend-test-log "CLAUDE SESSION READY")))

(define-command lem-yath-test-llm-backend-record () ()
  (let ((buffer (llm-output-buffer)))
    (llm-backend-test-log
     (concatenate
      'string
      "STATE active=~a openrouter=~a claude1=~a claude2=~a claude3=~a "
      "thinking=~a tool=~a tool-result=~a codex1=~a codex2=~a "
      "command=~a file=~a grok1=~a grok2=~a aborted=~a "
      "claude-id=~a codex-id=~a grok-id=~a claude-branch=~a claude-boundary=~a selected-backend=~a")
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
     (or (llm-cli-session-id :grok buffer) "none")
     (or (llm-cli-session-id :claude-code (current-buffer)) "none")
     (if (and (equal *llm-backend-test-claude-session-id*
                     "claude-session-1")
              (equal *llm-backend-test-claude-message-id*
                     "claude-message-boundary"))
         "yes" "no")
     *llm-backend*)))

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
  (define-key keymap "F10" 'lem-yath-test-llm-claude-session-setup)
  (define-key keymap "F12" 'lem-yath-test-llm-backend-record))

(setf (buffer-directory (current-buffer))
      (uiop:ensure-directory-pathname
       (uiop:getenv "LEM_YATH_LLM_CLAUDE_PROJECT_ROOT")))
(setf (buffer-directory (llm-output-buffer)) (user-homedir-pathname))

(setf *llm-request-finish-functions*
      (remove 'llm-backend-test-finish-metadata
              *llm-request-finish-functions*))
(push 'llm-backend-test-finish-metadata *llm-request-finish-functions*)

(llm-backend-test-log "READY")
