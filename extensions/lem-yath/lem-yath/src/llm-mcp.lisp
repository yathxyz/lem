;;;; Bounded stdio MCP client for the configured read-only fetch/GitHub tools.

(in-package :lem-yath)

(defparameter *llm-mcp-protocol-version* "2025-11-25")
(defparameter *llm-mcp-supported-protocol-versions*
  '("2025-11-25" "2025-06-18" "2025-03-26" "2024-11-05"))
(defparameter *llm-mcp-message-character-limit* (* 1024 1024))
(defparameter *llm-mcp-schema-character-limit* (* 64 1024))
(defparameter *llm-mcp-tool-count-limit* 128)
(defparameter *llm-mcp-page-count-limit* 8)
(defparameter *llm-mcp-content-block-limit* 128)
(defparameter *llm-mcp-start-timeout* 120)
(defparameter *llm-mcp-call-timeout* 90)
(defparameter *llm-mcp-github-toolsets*
  "context,repos,issues,pull_requests,users")
(defparameter *llm-mcp-github-image*
  "ghcr.io/github/github-mcp-server")

(defvar *llm-mcp-server-names* nil
  "Configured MCP server names captured by the active LLM preset.")

(defvar *llm-mcp-fetch-program*
  (or (uiop:getenv "LEM_YATH_MCP_FETCH_PROGRAM")
      (executable-find "mcp-server-fetch")
      (executable-find "uvx")))

(defvar *llm-mcp-docker-program*
  (or (uiop:getenv "LEM_YATH_MCP_DOCKER_PROGRAM")
      (executable-find "docker")))

(defstruct llm-mcp-server-spec
  name
  command
  environment)

(defstruct llm-mcp-tool
  exposed-name
  remote-name
  definition
  session)

(defstruct llm-mcp-session
  name
  process
  input
  output
  (next-id 0)
  protocol-version
  (tools #())
  (tools-dirty-p nil)
  (state :starting)
  (lock (bt2:make-lock :name "lem-yath/mcp-session")))

(defvar *llm-mcp-sessions* (make-hash-table :test #'equal))
(defvar *llm-mcp-sessions-lock*
  (bt2:make-lock :name "lem-yath/mcp-sessions"))

(defun llm-mcp-environment-entry-name (entry)
  (let ((equals (position #\= entry)))
    (and equals (subseq entry 0 equals))))

(defun llm-mcp-filter-environment (names)
  "Copy only NAMES from the editor environment."
  #+sbcl
  (loop :for entry :in (sb-ext:posix-environ)
        :for name := (llm-mcp-environment-entry-name entry)
        :when (member name names :test #'string=)
          :collect entry)
  #-sbcl
  (error "Safe MCP process environments require SBCL"))

(defun llm-mcp-environment-with (environment name value)
  (cons (format nil "~a=~a" name value)
        (remove name environment :key #'llm-mcp-environment-entry-name
                                 :test #'string=)))

(defparameter *llm-mcp-common-environment-names*
  '("HOME" "PATH" "TMPDIR" "XDG_CACHE_HOME" "XDG_CONFIG_HOME"
    "XDG_RUNTIME_DIR" "LANG" "LC_ALL" "SSL_CERT_FILE" "SSL_CERT_DIR"
    "NIX_SSL_CERT_FILE" "HTTP_PROXY" "HTTPS_PROXY" "NO_PROXY"
    "ALL_PROXY" "http_proxy" "https_proxy" "no_proxy" "all_proxy"))

(defparameter *llm-mcp-docker-environment-names*
  (append *llm-mcp-common-environment-names*
          '("DOCKER_HOST" "DOCKER_CONTEXT" "DOCKER_TLS_VERIFY"
            "DOCKER_CERT_PATH")))

(defun llm-mcp-github-token ()
  (or (uiop:getenv "GITHUB_PERSONAL_ACCESS_TOKEN")
      (uiop:getenv "GITHUB_TOKEN")))

(defun llm-mcp-safe-secret-p (value)
  (and (stringp value)
       (plusp (length value))
       (<= (length value) 4096)
       (not (find #\Null value))
       (not (find #\Newline value))
       (not (find #\Return value))))

(defun llm-mcp-fetch-command ()
  (when *llm-mcp-fetch-program*
    (let* ((program (namestring *llm-mcp-fetch-program*))
           (name (pathname-name (uiop:parse-native-namestring program))))
      (if (string= name "uvx")
          (list program "mcp-server-fetch")
          (list program)))))

(defun llm-mcp-server-available-p (name)
  (cond
    ((string= name "fetch") (not (null (llm-mcp-fetch-command))))
    ((string= name "github")
     (and *llm-mcp-docker-program*
          (llm-mcp-safe-secret-p (llm-mcp-github-token))))
    (t nil)))

(defun llm-mcp-configured-server-names ()
  (remove-if-not #'llm-mcp-server-available-p '("fetch" "github")))

(defun llm-mcp-server-spec-for (name)
  "Return the fixed read-only server specification for NAME."
  (cond
    ((string= name "fetch")
     (let ((command (llm-mcp-fetch-command)))
       (unless command (error "The fetch MCP server is unavailable"))
       (make-llm-mcp-server-spec
        :name name
        :command command
        :environment
        (llm-mcp-filter-environment *llm-mcp-common-environment-names*))))
    ((string= name "github")
     (let ((token (llm-mcp-github-token)))
       (unless (and *llm-mcp-docker-program*
                    (llm-mcp-safe-secret-p token))
         (error "The GitHub MCP server requires Docker and a GitHub token"))
       (let ((environment
               (llm-mcp-filter-environment
                *llm-mcp-docker-environment-names*)))
         (setf environment
               (llm-mcp-environment-with
                environment "GITHUB_PERSONAL_ACCESS_TOKEN" token)
               environment
               (llm-mcp-environment-with
                environment "GITHUB_TOOLSETS" *llm-mcp-github-toolsets*)
               environment
               (llm-mcp-environment-with environment "GITHUB_READ_ONLY" "1"))
         (make-llm-mcp-server-spec
          :name name
          :command
          (list (namestring *llm-mcp-docker-program*)
                "run" "-i" "--rm"
                "-e" "GITHUB_PERSONAL_ACCESS_TOKEN"
                "-e" "GITHUB_TOOLSETS"
                "-e" "GITHUB_READ_ONLY"
                *llm-mcp-github-image*)
          :environment environment))))
    (t (error "Unknown configured MCP server: ~a" name))))

(defun llm-mcp-json-text (object)
  (with-output-to-string (stream) (yason:encode object stream)))

(defun llm-mcp-write-message (session object)
  (let ((text (llm-mcp-json-text object)))
    (when (> (length text) *llm-mcp-message-character-limit*)
      (error "MCP request exceeds the message size limit"))
    (when (or (find #\Newline text) (find #\Return text))
      (error "MCP JSON encoder emitted an invalid stdio frame"))
    (write-line text (llm-mcp-session-input session))
    (finish-output (llm-mcp-session-input session))))

(defun llm-mcp-read-line (session timeout)
  "Read one bounded newline-delimited MCP frame from SESSION."
  (bt2:with-timeout (timeout)
    (let ((stream (llm-mcp-session-output session))
          (result (make-string-output-stream))
          (count 0))
      (loop :for character := (read-char stream nil nil)
            :do
               (when (null character)
                 (error "MCP server closed stdout"))
               (when (char= character #\Newline)
                 (return
                   (string-right-trim
                    '(#\Return) (get-output-stream-string result))))
               (incf count)
               (when (> count *llm-mcp-message-character-limit*)
                 (error "MCP response exceeds the message size limit"))
               (write-char character result)))))

(defun llm-mcp-parse-message (line)
  (handler-case
      (let ((message (yason:parse line)))
        (unless (and (hash-table-p message)
                     (string= (or (gethash "jsonrpc" message) "") "2.0"))
          (error "MCP server emitted an invalid JSON-RPC object"))
        message)
    (error (condition)
      (error "Malformed MCP JSON-RPC response: ~a" condition))))

(defun llm-mcp-error-response (id code message)
  (llm-json-object
   "jsonrpc" "2.0" "id" id
   "error" (llm-json-object "code" code "message" message)))

(defun llm-mcp-handle-server-message (session message)
  "Handle an interleaved server request/notification and return true."
  (multiple-value-bind (method method-p) (gethash "method" message)
    (when method-p
      (unless (stringp method)
        (error "MCP server emitted a non-string method"))
      (multiple-value-bind (id id-p) (gethash "id" message)
        (cond
          (id-p
           (unless (or (stringp id) (integerp id))
             (error "MCP server emitted an invalid request id"))
           (llm-mcp-write-message
            session
            (if (string= method "ping")
                (llm-json-object "jsonrpc" "2.0" "id" id
                                 "result" (llm-json-object))
                (llm-mcp-error-response id -32601
                                        "Client method is not supported"))))
          ((string= method "notifications/tools/list_changed")
           (setf (llm-mcp-session-tools-dirty-p session) t)))
        t))))

(defun llm-mcp-next-id (session)
  (incf (llm-mcp-session-next-id session)))

(defun llm-mcp-call-locked (session method &optional params
                            (timeout *llm-mcp-call-timeout*))
  "Make one synchronous JSON-RPC call while SESSION's lock is held."
  (let* ((id (llm-mcp-next-id session))
         (request (llm-json-object "jsonrpc" "2.0" "id" id
                                   "method" method)))
    (when params (setf (gethash "params" request) params))
    (llm-mcp-write-message session request)
    (loop
      :for message := (llm-mcp-parse-message
                       (llm-mcp-read-line session timeout))
      :unless (llm-mcp-handle-server-message session message)
        :do
           (multiple-value-bind (response-id id-p) (gethash "id" message)
             (unless (and id-p (eql response-id id))
               (error "MCP server returned an unexpected response id"))
             (multiple-value-bind (error-object error-p)
                 (gethash "error" message)
               (when error-p
                 (unless (hash-table-p error-object)
                   (error "MCP server returned a malformed error"))
                 (error "MCP ~a failed: ~a" method
                        (or (gethash "message" error-object) "unknown error"))))
             (multiple-value-bind (result result-p) (gethash "result" message)
               (unless (and result-p (hash-table-p result))
                 (error "MCP server returned a malformed result"))
               (return result))))))

(defun llm-mcp-notify-locked (session method &optional params)
  (let ((message (llm-json-object "jsonrpc" "2.0" "method" method)))
    (when params (setf (gethash "params" message) params))
    (llm-mcp-write-message session message)))

(defun llm-mcp-tool-name-valid-p (name)
  (and (stringp name)
       (<= 1 (length name) 128)
       (every (lambda (character)
                (or (and (char<= #\a character) (char<= character #\z))
                    (and (char<= #\A character) (char<= character #\Z))
                    (digit-char-p character)
                    (member character '(#\_ #\- #\.))))
              name)))

(defun llm-mcp-encode-tool-segment (name)
  (with-output-to-string (stream)
    (loop :for character :across name
          :do (case character
                (#\_ (write-string "__" stream))
                (#\. (write-string "_d" stream))
                (otherwise (write-char character stream))))))

(defun llm-mcp-exposed-tool-name (server-name remote-name)
  (let ((name (format nil "mcp__~a__~a" server-name
                      (llm-mcp-encode-tool-segment remote-name))))
    (when (> (length name) 128)
      (error "MCP tool name is too long to expose safely"))
    name))

(defun llm-mcp-tool-definition-from-json (session object)
  (unless (hash-table-p object)
    (error "MCP server advertised a malformed tool"))
  (let* ((remote-name (gethash "name" object))
         (description (gethash "description" object))
         (schema (gethash "inputSchema" object)))
    (unless (llm-mcp-tool-name-valid-p remote-name)
      (error "MCP server advertised an invalid tool name"))
    (unless (hash-table-p schema)
      (error "MCP tool ~a has no valid input schema" remote-name))
    (when (> (length (llm-mcp-json-text schema))
             *llm-mcp-schema-character-limit*)
      (error "MCP tool ~a has an oversized input schema" remote-name))
    (unless (or (null description) (stringp description))
      (error "MCP tool ~a has a malformed description" remote-name))
    (when (and description (> (length description) 16384))
      (error "MCP tool ~a has an oversized description" remote-name))
    (let ((exposed-name
            (llm-mcp-exposed-tool-name
             (llm-mcp-session-name session) remote-name)))
      (make-llm-mcp-tool
       :exposed-name exposed-name
       :remote-name remote-name
       :session session
       :definition
       (llm-json-object
        "type" "function"
        "function"
        (llm-json-object
         "name" exposed-name
         "description"
         (or description
             (format nil "Tool ~a from the ~a MCP server."
                     remote-name (llm-mcp-session-name session)))
         "parameters" schema))))))

(defun llm-mcp-list-tools-locked (session)
  (let ((cursor nil)
        (seen-cursors (make-hash-table :test #'equal))
        (tools '()))
    (loop :for page :from 1 :to *llm-mcp-page-count-limit*
          :for params := (and cursor (llm-json-object "cursor" cursor))
          :for result := (llm-mcp-call-locked
                           session "tools/list" params
                           *llm-mcp-start-timeout*)
          :do
             (dolist (object (llm-json-elements (gethash "tools" result)))
               (when (>= (length tools) *llm-mcp-tool-count-limit*)
                 (error "MCP server advertised too many tools"))
               (let ((tool (llm-mcp-tool-definition-from-json session object)))
                 (when (find (llm-mcp-tool-exposed-name tool) tools
                             :key #'llm-mcp-tool-exposed-name :test #'string=)
                   (error "MCP server advertised duplicate tool names"))
                 (push tool tools)))
             (setf cursor (gethash "nextCursor" result))
             (cond
               ((null cursor) (return))
               ((or (not (stringp cursor)) (> (length cursor) 4096)
                    (gethash cursor seen-cursors))
                (error "MCP server returned an invalid pagination cursor"))
               (t (setf (gethash cursor seen-cursors) t)))
          :finally (when cursor
                     (error "MCP tool pagination exceeded the page limit")))
    (setf (llm-mcp-session-tools session) (coerce (nreverse tools) 'vector)
          (llm-mcp-session-tools-dirty-p session) nil)))

(defun llm-mcp-initialize-session (session)
  (bt2:with-lock-held ((llm-mcp-session-lock session))
    (let* ((params
             (llm-json-object
              "protocolVersion" *llm-mcp-protocol-version*
              "capabilities" (llm-json-object)
              "clientInfo"
              (llm-json-object "name" "lem-yath" "version" "1")))
           (result
             (llm-mcp-call-locked
              session "initialize" params *llm-mcp-start-timeout*))
           (version (gethash "protocolVersion" result))
           (capabilities (gethash "capabilities" result)))
      (unless (member version *llm-mcp-supported-protocol-versions*
                      :test #'string=)
        (error "MCP server negotiated unsupported protocol version ~s" version))
      (unless (and (hash-table-p capabilities)
                   (hash-table-p (gethash "tools" capabilities)))
        (error "MCP server did not advertise tool support"))
      (setf (llm-mcp-session-protocol-version session) version)
      (llm-mcp-notify-locked session "notifications/initialized")
      (llm-mcp-list-tools-locked session)
      (setf (llm-mcp-session-state session) :ready)
      session)))

(defun llm-mcp-launch-session (spec)
  (let* ((process
           (uiop:launch-program
            (llm-mcp-server-spec-command spec)
            :directory (user-homedir-pathname)
            :environment (llm-mcp-server-spec-environment spec)
            :input :stream
            :output :stream
            ;; Stderr is deliberately ignored so it cannot block the server or
            ;; inject non-protocol text into stdout.
            :error-output nil
            :external-format :utf-8))
         (session
           (make-llm-mcp-session
            :name (llm-mcp-server-spec-name spec)
            :process process
            :input (uiop:process-info-input process)
            :output (uiop:process-info-output process))))
    session))

(defun llm-mcp-close-session (session)
  "Close SESSION without waiting for its request lock."
  (when session
    (setf (llm-mcp-session-state session) :closed)
    (ignore-errors (close (llm-mcp-session-input session)))
    (alexandria:when-let ((process (llm-mcp-session-process session)))
      (flet ((wait-briefly (seconds)
               (handler-case
                   (bt2:with-timeout (seconds)
                     (uiop:wait-process process)
                     t)
                 (bt2:timeout () nil)
                 (error () nil))))
        ;; MCP defines shutdown through the transport: close stdin, allow a
        ;; short graceful exit, then escalate TERM to KILL under hard bounds.
        (unless (wait-briefly 0.2)
          (ignore-errors (uiop:terminate-process process))
          (unless (wait-briefly 0.4)
            (ignore-errors (uiop:terminate-process process :urgent t))
            (wait-briefly 0.4))))
      (ignore-errors (uiop:close-streams process)))
    (setf (llm-mcp-session-process session) nil)))

(defun llm-mcp-remove-session (session)
  (bt2:with-lock-held (*llm-mcp-sessions-lock*)
    (when (eq session (gethash (llm-mcp-session-name session)
                               *llm-mcp-sessions*))
      (remhash (llm-mcp-session-name session) *llm-mcp-sessions*))))

(defun llm-mcp-session-usable-p (session)
  (and session
       (not (eq (llm-mcp-session-state session) :closed))
       (llm-mcp-session-process session)
       (ignore-errors
         (uiop:process-alive-p (llm-mcp-session-process session)))))

(defun llm-mcp-ensure-session (name)
  "Start and initialize configured server NAME, or reuse its live session."
  (let ((session nil)
        (new-p nil))
    (bt2:with-lock-held (*llm-mcp-sessions-lock*)
      (setf session (gethash name *llm-mcp-sessions*))
      (unless (llm-mcp-session-usable-p session)
        (when session (remhash name *llm-mcp-sessions*))
        (setf session (llm-mcp-launch-session
                       (llm-mcp-server-spec-for name))
              (gethash name *llm-mcp-sessions*) session
              new-p t)))
    (handler-case
        (if new-p
            (llm-mcp-initialize-session session)
            (bt2:with-lock-held ((llm-mcp-session-lock session))
              (unless (eq (llm-mcp-session-state session) :ready)
                (error "MCP server ~a did not become ready" name))
              session))
      (error (condition)
        (llm-mcp-remove-session session)
        (llm-mcp-close-session session)
        (error "Could not connect MCP server ~a: ~a" name condition)))))

(defun llm-mcp-ensure-servers (names)
  (mapcar #'llm-mcp-ensure-session names))

(defun llm-mcp-abort-server-names (names)
  "Terminate active configured NAMES so a blocked tool call is interrupted."
  (let ((sessions '()))
    (bt2:with-lock-held (*llm-mcp-sessions-lock*)
      (dolist (name names)
        (alexandria:when-let ((session (gethash name *llm-mcp-sessions*)))
          (remhash name *llm-mcp-sessions*)
          (push session sessions))))
    (dolist (session sessions) (llm-mcp-close-session session))))

(defun llm-mcp-stop-all ()
  (let ((names nil))
    (bt2:with-lock-held (*llm-mcp-sessions-lock*)
      (setf names (loop :for name :being :each :hash-key :of *llm-mcp-sessions*
                        :collect name)))
    (llm-mcp-abort-server-names names)
    (length names)))

(defun llm-mcp-all-tools (sessions)
  (loop :for session :in sessions
        :append (coerce (llm-mcp-session-tools session) 'list)))

(defun llm-mcp-tool-definitions (sessions)
  (coerce (mapcar #'llm-mcp-tool-definition
                  (llm-mcp-all-tools sessions))
          'vector))

(defun llm-mcp-find-tool (sessions exposed-name)
  (find exposed-name (llm-mcp-all-tools sessions)
        :key #'llm-mcp-tool-exposed-name :test #'string=))

(defun llm-mcp-render-content-block (block)
  (unless (hash-table-p block)
    (error "MCP tool returned a malformed content block"))
  (let ((type (gethash "type" block)))
    (cond
      ((string= type "text")
       (let ((text (gethash "text" block)))
         (unless (stringp text)
           (error "MCP text result is malformed"))
         text))
      ((string= type "resource_link")
       (format nil "[MCP resource: ~a~@[ (~a)~]]"
               (or (gethash "uri" block) "unknown")
               (gethash "name" block)))
      ((string= type "resource")
       (let ((resource (gethash "resource" block)))
         (unless (hash-table-p resource)
           (error "MCP embedded resource is malformed"))
         (or (gethash "text" resource)
             (format nil "[MCP binary resource omitted: ~a]"
                     (or (gethash "uri" resource) "unknown")))))
      ((member type '("image" "audio") :test #'string=)
       (format nil "[MCP ~a result omitted~@[ (~a)~]]"
               type (gethash "mimeType" block)))
      (t (format nil "[Unsupported MCP content block: ~a]" type)))))

(defun llm-mcp-render-tool-result (result)
  (let* ((blocks (llm-json-elements (gethash "content" result)))
         (structured (gethash "structuredContent" result))
         (error-p (eq (gethash "isError" result) t)))
    (when (> (length blocks) *llm-mcp-content-block-limit*)
      (error "MCP tool returned too many content blocks"))
    (let ((parts (mapcar #'llm-mcp-render-content-block blocks)))
      (when structured
        (setf parts
              (append parts
                      (list (format nil "Structured result:~%~a"
                                    (llm-mcp-json-text structured))))))
      (let ((text (if parts
                      (format nil "~{~a~^~2%~}" parts)
                      "MCP tool returned no content.")))
        (if error-p
            (format nil "MCP tool error: ~a" text)
            text)))))

(defun llm-mcp-invoke-tool (sessions exposed-name arguments)
  (let ((tool (llm-mcp-find-tool sessions exposed-name)))
    (unless tool (error "Unknown MCP tool: ~a" exposed-name))
    (let ((session (llm-mcp-tool-session tool)))
      (handler-case
          (bt2:with-lock-held ((llm-mcp-session-lock session))
            (unless (eq (llm-mcp-session-state session) :ready)
              (error "MCP server is not ready"))
            (when (llm-mcp-session-tools-dirty-p session)
              (llm-mcp-list-tools-locked session))
            (llm-mcp-render-tool-result
             (llm-mcp-call-locked
              session "tools/call"
              (llm-json-object
               "name" (llm-mcp-tool-remote-name tool)
               "arguments" arguments))))
        (error (condition)
          (llm-mcp-remove-session session)
          (llm-mcp-close-session session)
          (error "MCP tool ~a failed: ~a" exposed-name condition))))))

(define-command lem-yath-llm-mcp-connect-server () ()
  "Connect one configured read-only MCP server in the background."
  (let* ((names (llm-mcp-configured-server-names))
         (name (prompt-for-string
                "MCP server: "
                :completion-function (lambda (input)
                                       (prescient-filter input names)))))
    (if (not (member name names :test #'string=))
        (message "Unknown or unavailable MCP server: ~a" name)
        (bt2:make-thread
         (lambda ()
           (handler-case
               (let ((session (llm-mcp-ensure-session name)))
                 (send-event
                  (lambda ()
                    (message "MCP ~a connected with ~d tools"
                             name (length (llm-mcp-session-tools session))))))
             (error ()
               (send-event
                (lambda () (message "Could not connect MCP server ~a" name))))))
         :name "lem-yath/mcp-connect"))))

(define-command lem-yath-llm-mcp-connect-default () ()
  "Connect every available configured MCP server in the background."
  (let ((names (llm-mcp-configured-server-names)))
    (if (null names)
        (message "No MCP servers are available")
        (bt2:make-thread
         (lambda ()
           (handler-case
               (let ((sessions (llm-mcp-ensure-servers names)))
                 (send-event
                  (lambda ()
                    (message "Connected ~d MCP servers with ~d tools"
                             (length sessions)
                             (length (llm-mcp-all-tools sessions))))))
             (error ()
               (send-event
                (lambda () (message "Could not connect MCP servers"))))))
         :name "lem-yath/mcp-connect-all"))))

(define-command lem-yath-llm-mcp-stop-all () ()
  "Stop all MCP child processes owned by Lem-yath."
  (message "Stopped ~d MCP servers" (llm-mcp-stop-all)))

(define-command lem-yath-llm-mcp-status () ()
  "Report the connected MCP servers and exposed tool count."
  (let ((sessions nil))
    (bt2:with-lock-held (*llm-mcp-sessions-lock*)
      (setf sessions
            (loop :for session :being :each :hash-value :of *llm-mcp-sessions*
                  :when (and (eq (llm-mcp-session-state session) :ready)
                             (llm-mcp-session-usable-p session))
                    :collect session)))
    (if sessions
        (message "MCP: ~{~a~^, ~} (~d tools)"
                 (mapcar #'llm-mcp-session-name sessions)
                 (length (llm-mcp-all-tools sessions)))
        (message "No MCP servers connected"))))
