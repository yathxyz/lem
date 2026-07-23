(in-package :lem-yath)

(defvar *llm-oauth-test-report* (uiop:getenv "LEM_YATH_LLM_OAUTH_REPORT"))

(setf *llm-curl-executable* (uiop:getenv "LEM_YATH_LLM_OAUTH_CURL")
      *llm-grok-oauth-executable* (uiop:getenv "LEM_YATH_LLM_OAUTH_GROK")
      *llm-codex-open-browser* nil
      *llm-codex-login-port*
      (parse-integer (uiop:getenv "LEM_YATH_CODEX_TEST_PORT"))
      *llm-codex-redirect-uri*
      (format nil "http://localhost:~d/auth/callback"
              *llm-codex-login-port*))

(defun llm-oauth-test-log (control &rest arguments)
  (with-open-file (stream *llm-oauth-test-report*
                          :direction :output
                          :if-exists :append
                          :if-does-not-exist :create)
    (apply #'format stream control arguments)
    (terpri stream)))

(defun llm-oauth-test-buffer-text (name)
  (let ((buffer (get-buffer name)))
    (if (and buffer (not (deleted-buffer-p buffer)))
        (points-to-string (buffer-start-point buffer)
                          (buffer-end-point buffer))
        "")))

(defun llm-oauth-test-contains-p (name needle)
  (not (null (search needle (llm-oauth-test-buffer-text name)))))

(defun llm-oauth-test-mode (pathname)
  #+sbcl (logand (sb-posix:stat-mode
                  (sb-posix:stat (uiop:native-namestring pathname)))
                 #o777)
  #-sbcl 0)

(defun llm-oauth-test-header (name headers)
  (cdr (assoc name headers :test #'string=)))

(defun llm-oauth-test-login-state ()
  (let* ((text (llm-oauth-test-buffer-text *llm-codex-login-buffer-name*))
         (start (search "state=" text)))
    (when start
      (let* ((value-start (+ start 6))
             (end (or (position #\& text :start value-start)
                      (position #\Space text :start value-start)
                      (position #\Newline text :start value-start)
                      (length text))))
        (subseq text value-start end)))))

(define-command lem-yath-test-llm-oauth-static () ()
  (let ((failures 0))
    (labels ((check (condition name)
               (llm-oauth-test-log "~a STATIC ~a"
                                   (if condition "PASS" "FAIL") name)
               (unless condition (incf failures))))
      (let ((backends (llm-available-backends)))
        (check (and (member :chatgpt-codex backends)
                    (member :grok-oauth backends))
               "native-backend-selection"))
      (check (string= (cdr (assoc :chatgpt-codex
                                  *llm-backend-default-models*))
                      "gpt-5.4")
             "codex-default-model")
      (check (string= (cdr (assoc :grok-oauth *llm-backend-default-models*))
                      "grok-build")
             "grok-default-model")
      (check (and (assoc "codex-agentic" *llm-builtin-presets*
                         :test #'string=)
                  (assoc "grok-build-oauth-agentic" *llm-builtin-presets*
                         :test #'string=)
                  (llm-preset-valid-p
                   "native-tools"
                   '(:backend :chatgpt-codex :model "gpt-5.4"
                     :system "tools" :temperature 0.2 :max-tokens nil
                     :use-tools t :mcp-servers nil)))
             "configured-agentic-presets")
      (let* ((octets (make-array 6 :element-type '(unsigned-byte 8)
                                   :initial-contents '(0 1 2 253 254 255)))
             (encoded (llm-oauth-base64url-encode octets)))
        (check (equalp octets (llm-oauth-base64url-decode encoded))
               "base64url-roundtrip"))
      (multiple-value-bind (verifier challenge) (llm-codex-pkce)
        (check (and (= (length verifier) 43)
                    (= (length challenge) 43)
                    (not (string= verifier challenge)))
               "pkce-s256"))
      (check (string= (llm-codex-callback-code
                       "/auth/callback?code=code-1&state=state-1"
                       "state-1")
                      "code-1")
             "callback-state-validation")
      (let* ((tools (llm-tool-definitions))
             (body-text
               (llm-codex-request-body
                (list (llm-codex-message-item "user" "hello"))
                "gpt-5.4" "surgical" 0.2 nil tools "cache-1"))
             (body (yason:parse body-text))
             (wire-tools (llm-json-elements (gethash "tools" body)))
             (first-tool (first wire-tools)))
        (check (not (null (search "\"store\":false" body-text)))
               "responses-store-false")
        (check (eq (gethash "parallel_tool_calls" body) t)
               "responses-parallel-tools")
        (check (and (string= (gethash "model" body) "gpt-5.4")
                    (search *llm-codex-instructions-prefix*
                            (gethash "instructions" body)))
               "responses-model-instructions")
        (check (= (length wire-tools) 5)
               "responses-tool-count")
        (check (and (hash-table-p first-tool)
                    (null (gethash "function" first-tool))
                    (string= (gethash "type" first-tool) "function"))
               "responses-flat-tools")
        (check (not (null (search "\"additionalProperties\":false"
                                  body-text)))
               "responses-closed-schema"))
      (let* ((auth (llm-oauth-read-json-file
                    (llm-codex-auth-pathname) :required t))
             (headers (llm-codex-headers auth "session-1")))
        (check (and (llm-codex-auth-valid-p auth)
                    (not (llm-codex-auth-needs-refresh-p auth))
                    (search "Bearer x."
                            (llm-oauth-test-header "Authorization" headers))
                    (string= (llm-oauth-test-header "chatgpt-account-id" headers)
                             "acct-native")
                    (string= (llm-oauth-test-header "originator" headers)
                             "codex_cli_rs"))
               "codex-cli-auth-and-headers"))
      (let* ((credential (llm-grok-oauth-credential))
             (headers (llm-grok-oauth-headers credential "grok-build")))
        (check (and (llm-grok-oauth-expiring-p credential)
                    (string= (llm-oauth-test-header "X-XAI-Token-Auth" headers)
                             "xai-grok-cli")
                    (string= (llm-oauth-test-header
                              "x-grok-client-identifier" headers)
                             "grok-shell")
                    (string= (llm-oauth-test-header
                              "x-grok-model-override" headers)
                             "grok-build"))
               "grok-auth-expiry-and-headers"))
      (check (equal (rest (llm-curl-arguments
                           300 :stream-p t :status-p t))
                    '("--silent" "--show-error" "--fail-with-body"
                      "--no-buffer" "--write-out"
                      "\\n__LEM_YATH_HTTP_STATUS__:%{http_code}\\n"
                      "--max-time" "300" "--config" "-"))
             "secret-free-status-curl-argv")
      (let* ((buffer (llm-output-buffer))
             (*llm-backend* :chatgpt-codex))
        (setf (buffer-value buffer (llm-oauth-history-key :chatgpt-codex))
              (list (llm-codex-message-item "user" "old")))
        (lem-yath-llm-new-session)
        (check (null (llm-oauth-history :chatgpt-codex buffer))
               "native-new-session"))
      (llm-oauth-test-log "SUMMARY STATIC ~a failures=~d"
                          (if (zerop failures) "PASS" "FAIL") failures))))

(define-command lem-yath-test-codex-refresh () ()
  (handler-case
      (let* ((auth (llm-codex-refresh-auth t))
             (tokens (llm-codex-token-object auth)))
        (llm-oauth-test-log
         "REFRESH ~a preserve=~a rotated=~a mode=~3,'0o"
         (if (llm-codex-auth-valid-p auth) "pass" "fail")
         (if (string= (gethash "unknown_top" auth) "preserve-me")
             "yes" "no")
         (if (search "codex-rotated-refresh-secret-"
                     (gethash "refresh_token" tokens))
             "yes" "no")
         (llm-oauth-test-mode (llm-codex-auth-pathname))))
    (error (condition)
      (llm-oauth-test-log "REFRESH fail ~a" condition))))

(define-command lem-yath-test-codex-native () ()
  (setf *llm-backend* :chatgpt-codex
        *llm-model* "gpt-5.4"
        *llm-system-message*
        "You are a coding agent. Use available tools first for project discovery, then answer with concrete, minimal steps or code edits."
        *llm-temperature* 0.2
        *llm-max-tokens* nil
        *llm-use-tools* t)
  (llm-backend-stream :chatgpt-codex "codex native prompt"))

(define-command lem-yath-test-grok-native () ()
  (setf *llm-backend* :grok-oauth
        *llm-model* "grok-build"
        *llm-system-message*
        "You are a coding assistant. Use available tools first for project discovery, then answer with concrete, minimal steps or code edits."
        *llm-temperature* 0.2
        *llm-max-tokens* nil
        *llm-use-tools* t)
  (llm-backend-stream :grok-oauth "grok native prompt"))

(define-command lem-yath-test-codex-login () ()
  (lem-yath-chatgpt-codex-login))

(define-command lem-yath-test-llm-oauth-reload () ()
  (let ((source (asdf:system-relative-pathname
                 "lem-yath" "src/apps/llm-oauth.lisp")))
    (handler-case
        (progn
          (load source)
          (load source)
          (llm-oauth-test-log
           "RELOAD pass codex=~a grok=~a"
           (if (compute-applicable-methods
                #'llm-backend-stream (list :chatgpt-codex "probe"))
               "present" "missing")
           (if (compute-applicable-methods
                #'llm-backend-stream (list :grok-oauth "probe"))
               "present" "missing")))
      (error (condition)
        (llm-oauth-test-log "RELOAD fail ~a" condition)))))

(define-command lem-yath-test-llm-oauth-record () ()
  (let* ((output (llm-output-buffer))
         (codex-history (llm-oauth-history :chatgpt-codex output))
         (grok-history (llm-oauth-history :grok-oauth output))
         (state (llm-oauth-test-login-state)))
    (llm-oauth-test-log
     (concatenate
      'string
      "STATE active=~a codex=~a grok=~a tools=~a codex-history=~d "
      "grok-history=~d login-wait=~a login-done=~a auth-mode=~3,'0o")
     (if (llm-active-request output) "yes" "no")
     (if (llm-oauth-test-contains-p *llm-buffer-name* "Codex native answer")
         "yes" "no")
     (if (llm-oauth-test-contains-p *llm-buffer-name* "Grok native answer")
         "yes" "no")
     (if (llm-oauth-test-contains-p *llm-buffer-name* "### Tool result")
         "yes" "no")
     (length codex-history)
     (length grok-history)
     (if state "yes" "no")
     (if (llm-oauth-test-contains-p *llm-codex-login-buffer-name*
                                    "Authorization complete")
         "yes" "no")
     (if (uiop:file-exists-p (llm-codex-auth-pathname))
         (llm-oauth-test-mode (llm-codex-auth-pathname)) 0))
    (when state (llm-oauth-test-log "LOGIN_STATE ~a" state))))

(dolist (keymap (list *global-keymap*
                      lem-vi-mode:*normal-keymap*
                      lem-vi-mode:*insert-keymap*
                      lem-vi-mode:*visual-keymap*))
  (define-key keymap "F2" 'lem-yath-test-llm-oauth-static)
  (define-key keymap "F3" 'lem-yath-test-codex-refresh)
  (define-key keymap "F4" 'lem-yath-test-codex-native)
  (define-key keymap "F5" 'lem-yath-test-grok-native)
  (define-key keymap "F6" 'lem-yath-test-codex-login)
  (define-key keymap "F9" 'lem-yath-test-llm-oauth-reload)
  (define-key keymap "F12" 'lem-yath-test-llm-oauth-record))

(llm-oauth-test-log "READY")
