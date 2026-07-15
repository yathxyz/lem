(in-package :lem-yath)

(defvar *llm-mcp-test-report* (uiop:getenv "LEM_YATH_LLM_MCP_REPORT"))
(defvar *llm-mcp-test-root*
  (canonical-project-directory (uiop:getenv "LEM_YATH_LLM_MCP_PROJECT")))
(defvar *llm-mcp-test-source* (merge-pathnames "source.lisp" *llm-mcp-test-root*))

(setf *llm-curl-executable* (uiop:getenv "LEM_YATH_LLM_MCP_CURL"))

(defun llm-mcp-test-log (control &rest arguments)
  (with-open-file (stream *llm-mcp-test-report*
                          :direction :output :if-exists :append
                          :if-does-not-exist :create)
    (apply #'format stream control arguments)
    (terpri stream)))

(defun llm-mcp-test-check (condition name failures)
  (llm-mcp-test-log "~a STATIC ~a" (if condition "PASS" "FAIL") name)
  (unless condition (incf (car failures))))

(defun llm-mcp-test-signals-error-p (function)
  (handler-case (progn (funcall function) nil)
    (error () t)))

(defun llm-mcp-test-context (&optional sessions names)
  (make-llm-tool-context
   :root *llm-mcp-test-root*
   :project-request
   (make-live-project-request 0 (capture-project-request-origin))
   :mcp-server-names names
   :mcp-sessions sessions))

(defun llm-mcp-test-buffer-text ()
  (let ((buffer (llm-output-buffer)))
    (points-to-string (buffer-start-point buffer) (buffer-end-point buffer))))

(define-command lem-yath-test-llm-mcp-static () ()
  (let ((failures (list 0)))
    (labels ((check (condition name)
               (llm-mcp-test-check condition name failures)))
      (unwind-protect
           (progn
             (check (equal (llm-mcp-configured-server-names)
                           '("fetch" "github"))
                    "exact-configured-servers")
             (let* ((fetch (llm-mcp-server-spec-for "fetch"))
                    (github (llm-mcp-server-spec-for "github"))
                    (github-command (llm-mcp-server-spec-command github))
                    (github-environment (llm-mcp-server-spec-environment github)))
               (check (= (length (llm-mcp-server-spec-command fetch)) 1)
                      "pinned-fetch-direct-argv")
               (check (equal (subseq github-command 1)
                             '("run" "-i" "--rm"
                               "-e" "GITHUB_PERSONAL_ACCESS_TOKEN"
                               "-e" "GITHUB_TOOLSETS"
                               "-e" "GITHUB_READ_ONLY"
                               "ghcr.io/github/github-mcp-server"))
                      "github-direct-readonly-argv")
               (check (and (not (find-if
                                 (lambda (argument)
                                   (search "fixture-github-token" argument))
                                 github-command))
                           (find "GITHUB_PERSONAL_ACCESS_TOKEN=fixture-github-token"
                                 github-environment :test #'string=)
                           (find "GITHUB_READ_ONLY=1" github-environment
                                 :test #'string=)
                           (not (find-if
                                 (lambda (entry)
                                   (search "UNRELATED_SECRET=" entry))
                                 github-environment)))
                      "github-credential-confinement"))
             (llm-load-preset "web-readonly")
             (check (and *llm-use-tools*
                         (equal *llm-mcp-server-names* '("fetch")))
                    "web-preset-fetch-only")
             (llm-save-preset "saved-web-fixture")
             (llm-load-preset "quick-lookup")
             (check (null *llm-mcp-server-names*) "quick-preset-mcp-free")
             (llm-load-preset "saved-web-fixture")
             (check (equal *llm-mcp-server-names* '("fetch"))
                    "persist-mcp-server-policy")
             (check
              (null
               (llm-preset-from-json
                (llm-json-object
                 "name" "malformed-mcp-policy"
                 "backend" "openrouter"
                 "model" "openrouter/auto"
                 "system" "read only"
                 "temperature" 0.2
                 "max_tokens" 1000
                 "use_tools" t
                 "mcp_servers" "fetch")))
              "reject-malformed-persisted-mcp-policy")
             (check
              (llm-mcp-test-signals-error-p
               (lambda () (llm-mcp-parse-message "not-json")))
              "reject-malformed-jsonrpc")
             (check
              (llm-mcp-test-signals-error-p
               (lambda ()
                 (llm-mcp-read-line
                  (make-llm-mcp-session
                   :name "oversized"
                   :output
                   (make-string-input-stream
                    (concatenate
                     'string
                     (make-string
                      (1+ *llm-mcp-message-character-limit*)
                      :initial-element #\x)
                     (string #\Newline))))
                  2)))
              "bound-jsonrpc-line")
             (let* ((fetch (llm-mcp-ensure-session "fetch"))
                    (same (llm-mcp-ensure-session "fetch"))
                    (sessions (list fetch))
                    (context (llm-mcp-test-context sessions '("fetch")))
                    (definitions (llm-tool-definitions sessions))
                    (names
                      (loop :for definition :across definitions
                            :collect (gethash
                                      "name" (gethash "function" definition))))
                    (result
                      (llm-invoke-tool
                       context "mcp__fetch__fetch"
                       "{\"url\":\"https://example.invalid/static\"}")))
               (unwind-protect
                    (progn
                      (check (eq fetch same) "persistent-session-reuse")
                      (check (string= (llm-mcp-session-protocol-version fetch)
                                      "2025-06-18")
                             "older-version-negotiation")
                      (check (equal (subseq names 5)
                                    '("mcp__fetch__fetch"
                                      "mcp__fetch__fetch_dheaders"))
                             "paginated-namespaced-tools")
                      (check (and (search "FETCH-FIRST" result)
                                  (search "FETCH-SECOND" result)
                                  (< (search "FETCH-FIRST" result)
                                     (search "FETCH-SECOND" result))
                                  (search "https://example.invalid/static" result))
                             "text-and-structured-result"))
                 (cancel-project-request
                  (llm-tool-context-project-request context))))
             (let* ((github (llm-mcp-ensure-session "github"))
                    (context (llm-mcp-test-context (list github) '("github"))))
               (unwind-protect
                    (check (search "GITHUB-READONLY"
                                   (llm-invoke-tool context
                                                    "mcp__github__get__me"
                                                    "{}"))
                           "github-tool-call")
                 (cancel-project-request
                  (llm-tool-context-project-request context))))
             (check
              (llm-mcp-test-signals-error-p
               (lambda ()
                 (llm-mcp-tool-definition-from-json
                  (make-llm-mcp-session :name "bad")
                  (llm-json-object "name" "bad name"
                                   "inputSchema" (llm-json-object)))))
              "reject-invalid-server-tool")
             (let* ((fetch (llm-mcp-ensure-session "fetch"))
                    (context (llm-mcp-test-context (list fetch) '("fetch")))
                    (result nil)
                    (started (get-internal-real-time))
                    (thread
                      (bt2:make-thread
                       (lambda ()
                         (setf result
                               (llm-invoke-tool context "mcp__fetch__fetch"
                                                "{\"url\":\"delay\"}")))
                       :name "lem-yath/mcp-cancel-test")))
               (sleep 0.2)
               (llm-mcp-abort-server-names '("fetch"))
               (bt2:join-thread thread)
               (check (and (search "Tool error" result)
                           (< (/ (- (get-internal-real-time) started)
                                 internal-time-units-per-second)
                              5))
                      "abort-interrupts-mcp-call")
               (cancel-project-request
                (llm-tool-context-project-request context)))
             (llm-mcp-stop-all)
             (check (zerop (hash-table-count *llm-mcp-sessions*))
                    "stop-all-cleans-hub"))
        (llm-mcp-stop-all))
      (llm-mcp-test-log "SUMMARY STATIC ~a failures=~d"
                        (if (zerop (car failures)) "PASS" "FAIL")
                        (car failures)))))

(define-command lem-yath-test-llm-mcp-send () ()
  (find-file *llm-mcp-test-source*)
  (llm-load-preset "web-readonly")
  (llm-stream "Use the read-only fetch MCP tool.")
  (llm-mcp-test-log "SEND started"))

(define-command lem-yath-test-llm-mcp-record () ()
  (let ((text (llm-mcp-test-buffer-text))
        (buffer (llm-output-buffer)))
    (llm-mcp-test-log
     "STATE active=~a final=~a tool=~a protocol-error=~a"
     (if (llm-active-request buffer) "yes" "no")
     (if (search "MCP agent complete" text) "yes" "no")
     (if (search "FETCH-FIRST" text) "yes" "no")
     (if (or (search "protocol error" text :test #'char-equal)
             (search "connection error" text :test #'char-equal))
         "yes" "no"))))

(dolist (keymap (list *global-keymap* lem-vi-mode:*normal-keymap*
                      lem-vi-mode:*insert-keymap* lem-vi-mode:*visual-keymap*))
  (define-key keymap "F2" 'lem-yath-test-llm-mcp-static)
  (define-key keymap "F3" 'lem-yath-test-llm-mcp-send)
  (define-key keymap "F12" 'lem-yath-test-llm-mcp-record))

(llm-mcp-test-log "READY")
