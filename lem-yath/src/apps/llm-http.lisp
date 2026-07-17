;;;; lem-yath apps/llm-http -- gptel-compatible Perplexity and Copilot chat.

(in-package :lem-yath)

(defvar *llm-perplexity-endpoint*
  "https://api.perplexity.ai/chat/completions")
(defvar *llm-copilot-chat-endpoint*
  "https://api.githubcopilot.com/chat/completions")
(defvar *llm-copilot-token-endpoint*
  "https://api.github.com/copilot_internal/v2/token")
(defvar *llm-copilot-device-endpoint*
  "https://github.com/login/device/code")
(defvar *llm-copilot-oauth-endpoint*
  "https://github.com/login/oauth/access_token")

(defparameter *llm-copilot-client-id* "Iv1.b507a08c87ecfe98")
(defparameter *llm-http-output-limit* (* 4 1024 1024))
(defparameter *llm-http-request-timeout* 30)
(defparameter *llm-http-stream-timeout* 300)
(defparameter *llm-http-token-file-limit* (* 32 1024))
(defparameter *llm-http-citation-count-limit* 50)
(defparameter *llm-http-citation-length-limit* 4096)
(defparameter *llm-copilot-token-expiry-margin* 60)

(defvar *llm-copilot-open-browser* t
  "Whether Copilot login may open the verification URL outside SSH.")
(defvar *llm-copilot-login-running-p* nil)
(defvar *llm-copilot-login-lock*
  (bt2:make-lock :name "lem-yath/copilot-login"))
(defvar *llm-copilot-login-buffer-name* "*lem-yath-copilot-login*")

(defun llm-http-random-hex (length)
  (let ((digits "0123456789abcdef"))
    (coerce (loop :repeat length
                  :collect (char digits (random (length digits))))
            'string)))

(defun llm-http-uuid ()
  (format nil "~a-~a-4~a-8~a-~a"
          (llm-http-random-hex 8)
          (llm-http-random-hex 4)
          (llm-http-random-hex 3)
          (llm-http-random-hex 3)
          (llm-http-random-hex 12)))

(defvar *llm-copilot-machine-id* (llm-http-random-hex 65))

(defun llm-http-json-request (method url headers &optional body)
  "Run a bounded JSON HTTP request without putting sensitive data in argv."
  (let ((*project-process-timeout* (+ *llm-http-request-timeout* 2)))
    (multiple-value-bind (output error-output status)
        (run-project-program
         (llm-curl-arguments *llm-http-request-timeout*)
         :input (llm-curl-config method url headers body)
         :output-limit *llm-http-output-limit*)
      (declare (ignore error-output))
      (unless (and (integerp status) (zerop status))
        (error "HTTP request failed (exit ~a)" status))
      (handler-case
          (yason:parse output)
        (error () (error "HTTP service returned malformed JSON"))))))

(defun llm-http-provider-name (provider)
  (ecase provider
    (:perplexity "Perplexity")
    (:copilot "Copilot")))

(defun llm-http-valid-citation-p (value)
  (and (stringp value)
       (plusp (length value))
       (<= (length value) *llm-http-citation-length-limit*)
       (every (lambda (character)
                (not (member character '(#\Newline #\Return #\Tab))))
              value)))

(defun llm-http-response-citations (json)
  (let* ((values (and (hash-table-p json) (gethash "citations" json)))
         (citations
           (remove-duplicates
            (remove-if-not #'llm-http-valid-citation-p
                           (llm-json-elements values))
            :test #'string=)))
    (subseq citations 0 (min (length citations)
                             *llm-http-citation-count-limit*))))

(defun llm-http-render-citations (citations)
  (when citations
    (with-output-to-string (stream)
      (format stream "~2%Citations:~%")
      (loop :for citation :in citations
            :for index :from 1
            :do (format stream "[~d] ~a~%" index citation)))))

(defun llm-http-read-stream (request process provider)
  "Read one bounded OpenAI-compatible SSE response and return citations."
  (let ((content-count 0)
        (citations nil))
    (with-open-stream (output (uiop:process-info-output process))
      (loop :for line := (read-line output nil)
            :while line
            :do
               (multiple-value-bind (json data-p done-p) (llm-sse-json line)
                 (when done-p (return))
                 (when (and data-p (hash-table-p json))
                   (when (gethash "error" json)
                     (error "~a returned an API error"
                            (llm-http-provider-name provider)))
                   (when (eq provider :perplexity)
                     (alexandria:when-let ((found
                                            (llm-http-response-citations json)))
                       (setf citations found)))
                   (let ((choice
                           (first (llm-json-elements
                                   (gethash "choices" json)))))
                     (when (hash-table-p choice)
                       (let* ((delta (gethash "delta" choice))
                              (chunk (and (hash-table-p delta)
                                          (gethash "content" delta))))
                         (when (stringp chunk)
                           (incf content-count (length chunk))
                           (when (> content-count
                                    *llm-response-character-limit*)
                             (error "~a response exceeded the size limit"
                                    (llm-http-provider-name provider)))
                           (llm-request-append request chunk)))))))))
    citations))

(defun llm-http-stream-round (request provider url headers body)
  "Run one provider SSE request, returning citations and curl status."
  (let ((process (llm-launch-curl-stream
                  "POST" url headers body *llm-http-stream-timeout*))
        (finished-p nil))
    (unless (llm-request-install-process request process)
      (ignore-errors (uiop:terminate-process process :urgent t))
      (ignore-errors (uiop:wait-process process))
      (return-from llm-http-stream-round (values nil nil)))
    (unwind-protect
         (let ((citations (llm-http-read-stream request process provider))
               (status (uiop:wait-process process)))
           (setf finished-p t)
           (values citations status))
      (unless finished-p
        (ignore-errors (uiop:terminate-process process :urgent t))
        (ignore-errors (uiop:wait-process process)))
      (llm-request-release-process request process))))

(defun llm-http-token-valid-p (token)
  (and (stringp token)
       (plusp (length token))
       (<= (length token) 16384)
       (every (lambda (character)
                (and (graphic-char-p character)
                     (not (member character '(#\Newline #\Return #\Tab)))))
              token)))

(defun llm-http-unix-time ()
  (- (get-universal-time) 2208988800))

(defun llm-copilot-cache-directory ()
  (alexandria:if-let ((override
                        (uiop:getenv "LEM_YATH_COPILOT_TOKEN_DIRECTORY")))
    (uiop:ensure-directory-pathname
     (uiop:parse-native-namestring override))
    (let ((cache-home
            (alexandria:if-let ((xdg (uiop:getenv "XDG_CACHE_HOME")))
              (uiop:ensure-directory-pathname
               (uiop:parse-native-namestring xdg))
              (merge-pathnames ".cache/" (user-homedir-pathname)))))
      (merge-pathnames "lem-yath/copilot/" cache-home))))

(defun llm-copilot-token-pathname (kind)
  (merge-pathnames (ecase kind
                     (:github "github-token.json")
                     (:session "session-token.json"))
                   (llm-copilot-cache-directory)))

(defun llm-copilot-prepare-private-directory ()
  (let* ((directory (llm-copilot-cache-directory))
         (existed (uiop:directory-exists-p directory))
         (override (uiop:getenv "LEM_YATH_COPILOT_TOKEN_DIRECTORY")))
    (ensure-directories-exist (merge-pathnames "token" directory))
    #+sbcl
    (progn
      (when (or (not override) (not existed))
        (sb-posix:chmod (uiop:native-namestring directory) #o700))
      (let ((stat (sb-posix:lstat (uiop:native-namestring directory))))
        (unless (and (= (logand (sb-posix:stat-mode stat) sb-posix:s-ifmt)
                        sb-posix:s-ifdir)
                     (= (sb-posix:stat-uid stat) (sb-posix:getuid))
                     (zerop (logand (sb-posix:stat-mode stat) #o077)))
          (error "Copilot token directory must be private and user-owned"))))
    #-sbcl (error "Safe Copilot token storage requires SBCL")
    directory))

(defun llm-copilot-validate-token-file (pathname)
  (when (uiop:file-exists-p pathname)
    #+sbcl
    (let ((stat (sb-posix:lstat (uiop:native-namestring pathname))))
      (unless (and (= (logand (sb-posix:stat-mode stat) sb-posix:s-ifmt)
                      sb-posix:s-ifreg)
                   (= (sb-posix:stat-uid stat) (sb-posix:getuid))
                   (zerop (logand (sb-posix:stat-mode stat) #o077)))
        (error "Copilot token file must be private, regular, and user-owned")))
    #-sbcl (error "Safe Copilot token storage requires SBCL")))

(defun llm-copilot-read-token-object (kind)
  (let ((pathname (llm-copilot-token-pathname kind)))
    (when (uiop:file-exists-p pathname)
      (llm-copilot-validate-token-file pathname)
      (with-open-file (stream pathname :element-type '(unsigned-byte 8))
        (let ((length (file-length stream)))
          (when (> length *llm-http-token-file-limit*)
            (error "Copilot token file exceeds the size limit"))
          (let ((octets (make-array length :element-type '(unsigned-byte 8))))
            (unless (= length (read-sequence octets stream))
              (error "Could not read the complete Copilot token file"))
            (handler-case
                (yason:parse
                 #+sbcl (sb-ext:octets-to-string
                          octets :external-format :utf-8)
                 #-sbcl (error "UTF-8 token decoding requires SBCL"))
              (error () (error "Copilot token file contains malformed JSON")))))))))

(defun llm-copilot-temporary-pathname (pathname)
  (uiop:parse-native-namestring
   (format nil "~a.tmp.~d.~a"
           (uiop:native-namestring pathname)
           #+sbcl (sb-posix:getpid)
           #-sbcl 0
           (llm-http-random-hex 16))))

(defun llm-copilot-write-token-object (kind object)
  "Atomically persist OBJECT as a private JSON token file."
  (llm-copilot-prepare-private-directory)
  (let* ((pathname (llm-copilot-token-pathname kind))
         (temporary (llm-copilot-temporary-pathname pathname))
         (text (with-output-to-string (stream) (yason:encode object stream)))
         (octets #+sbcl (sb-ext:string-to-octets
                         text :external-format :utf-8)
                 #-sbcl (error "UTF-8 token encoding requires SBCL"))
         (descriptor nil)
         (stream nil))
    (when (> (length octets) *llm-http-token-file-limit*)
      (error "Refusing an oversized Copilot token"))
    (unwind-protect
         (progn
           #+sbcl
           (progn
             (setf descriptor
                   (sb-posix:open
                    (uiop:native-namestring temporary)
                    (logior sb-posix:o-creat sb-posix:o-excl
                            sb-posix:o-wronly sb-posix:o-nofollow)
                    #o600))
             (sb-posix:fchmod descriptor #o600)
             (setf stream
                   (sb-sys:make-fd-stream
                    descriptor :output t :element-type '(unsigned-byte 8)
                    :buffering :full
                    :name (uiop:native-namestring temporary)))
             (write-sequence octets stream)
             (finish-output stream)
             (sb-posix:fsync descriptor)
             (close stream)
             (setf stream nil descriptor nil))
           #-sbcl (error "Safe Copilot token storage requires SBCL")
           (uiop:rename-file-overwriting-target temporary pathname)
           #+sbcl (sb-posix:chmod (uiop:native-namestring pathname) #o600)
           object)
      (when stream
        (ignore-errors (close stream :abort t))
        (setf descriptor nil))
      (when descriptor (ignore-errors (sb-posix:close descriptor)))
      (when (uiop:file-exists-p temporary)
        (ignore-errors (delete-file temporary))))))

(defun llm-copilot-delete-token (kind)
  (let ((pathname (llm-copilot-token-pathname kind)))
    (when (uiop:file-exists-p pathname)
      (llm-copilot-validate-token-file pathname)
      (delete-file pathname))))

(defun llm-copilot-github-token ()
  (let* ((object (llm-copilot-read-token-object :github))
         (token (and (hash-table-p object)
                     (gethash "access_token" object))))
    (and (llm-http-token-valid-p token) token)))

(defun llm-copilot-session-token-current-p (object)
  (let ((token (and (hash-table-p object) (gethash "token" object)))
        (expiry (and (hash-table-p object) (gethash "expires_at" object))))
    (and (llm-http-token-valid-p token)
         (integerp expiry)
         (> expiry (+ (llm-http-unix-time)
                      *llm-copilot-token-expiry-margin*)))))

(defun llm-copilot-renew-session-token (github-token)
  (let* ((response
           (llm-http-json-request
            "GET" *llm-copilot-token-endpoint*
            `(("Authorization" . ,(format nil "token ~a" github-token))
              ("Accept" . "application/json")
              ("editor-plugin-version" . "gptel/*")
              ("editor-version" . "lem/lem-yath"))))
         (token (and (hash-table-p response) (gethash "token" response)))
         (expiry (and (hash-table-p response)
                      (gethash "expires_at" response))))
    (unless (and (llm-http-token-valid-p token) (integerp expiry))
      (error "GitHub did not grant a Copilot Chat token"))
    (llm-copilot-write-token-object
     :session (llm-json-object "token" token "expires_at" expiry))))

(defun llm-copilot-session-token (github-token)
  (let ((object (llm-copilot-read-token-object :session)))
    (unless (llm-copilot-session-token-current-p object)
      (setf object (llm-copilot-renew-session-token github-token)))
    (gethash "token" object)))

(defun llm-copilot-headers (token)
  `(("Content-Type" . "application/json")
    ("Accept" . "text/event-stream")
    ("openai-intent" . "conversation-panel")
    ("Authorization" . ,(format nil "Bearer ~a" token))
    ("x-initiator" . "user")
    ("x-request-id" . ,(llm-http-uuid))
    ("vscode-sessionid" . "")
    ("vscode-machineid" . ,*llm-copilot-machine-id*)
    ("copilot-integration-id" . "vscode-chat")))

(defun llm-http-provider-credentials (provider)
  (ecase provider
    (:perplexity
     (let ((key (uiop:getenv "PERPLEXITY_API_KEY")))
       (unless (llm-http-token-valid-p key)
         (error "Set PERPLEXITY_API_KEY first"))
       (values *llm-perplexity-endpoint*
               `(("Content-Type" . "application/json")
                 ("Accept" . "text/event-stream")
                 ("Authorization" . ,(format nil "Bearer ~a" key))))))
    (:copilot
     (let ((github-token (llm-copilot-github-token)))
       (unless github-token
         (error "Run M-x lem-yath-copilot-login first"))
       (values *llm-copilot-chat-endpoint*
               (llm-copilot-headers
                (llm-copilot-session-token github-token)))))))

(defun llm-http-stream (provider prompt)
  "Stream PROMPT through Perplexity or GitHub Copilot Chat."
  (when (and (eq provider :perplexity)
             (not (llm-http-token-valid-p
                   (uiop:getenv "PERPLEXITY_API_KEY"))))
    (message "Set PERPLEXITY_API_KEY first")
    (return-from llm-http-stream))
  (when (and (eq provider :copilot)
             (handler-case (null (llm-copilot-github-token))
               (error () t)))
    (message "Run M-x lem-yath-copilot-login first")
    (return-from llm-http-stream))
  (let* ((buffer (llm-output-buffer))
         (model *llm-model*)
         (system *llm-system-message*)
         (temperature *llm-temperature*)
         (max-tokens *llm-max-tokens*)
         (messages (llm-messages-with-system prompt system)))
    (when (llm-active-request buffer)
      (message "An LLM request is already running; use M-x lem-yath-llm-abort")
      (return-from llm-http-stream))
    (let* ((insertion-point
             (llm-prepare-response
              buffer
              (format nil "~%## User (~a / ~a)~%~%~a~%~%## Assistant~%~%"
                      (llm-http-provider-name provider) model prompt)))
           (request (llm-register-request
                     buffer nil provider :prompt prompt
                     :insertion-point insertion-point)))
      (llm-start-request-thread
       request
       (lambda ()
         (handler-case
             (multiple-value-bind (url headers)
                 (llm-http-provider-credentials provider)
               (let ((body
                       (llm-request-body-for-messages
                        messages
                        model temperature max-tokens nil)))
                 (multiple-value-bind (citations status)
                     (llm-http-stream-round request provider url headers body)
                   (unless (llm-request-aborted-now-p request)
                     (llm-request-finish
                      request
                      (if (and (integerp status) (zerop status))
                          (or (llm-http-render-citations citations)
                              (string #\Newline))
                          (llm-request-finish-text
                           request status
                           (format nil "~a request failed"
                                   (llm-http-provider-name provider)))))))))
           (error (condition)
             (unless (llm-request-aborted-now-p request)
               (llm-request-finish
                request
                (format nil "~%[~a protocol error: ~a]~%"
                        (llm-http-provider-name provider) condition))))))
       (format nil "lem-yath/llm-~(~a~)" provider)
       (format nil "~%[failed to start ~a request]~%"
               (llm-http-provider-name provider))))))

(defmethod llm-backend-stream ((backend (eql :perplexity)) prompt)
  (llm-http-stream backend prompt))

(defmethod llm-backend-stream ((backend (eql :copilot)) prompt)
  (llm-http-stream backend prompt))

(defun llm-copilot-login-claim ()
  (bt2:with-lock-held (*llm-copilot-login-lock*)
    (unless *llm-copilot-login-running-p*
      (setf *llm-copilot-login-running-p* t))))

(defun llm-copilot-login-release ()
  (bt2:with-lock-held (*llm-copilot-login-lock*)
    (setf *llm-copilot-login-running-p* nil)))

(defun llm-copilot-login-buffer ()
  (let ((buffer (make-buffer *llm-copilot-login-buffer-name*)))
    (handler-case
        (change-buffer-mode buffer 'lem-markdown-mode:markdown-mode)
      (error () nil))
    buffer))

(defun llm-copilot-login-publish (text &key code url)
  (send-event
   (lambda ()
     (let ((buffer (llm-copilot-login-buffer)))
       (pop-to-buffer buffer)
       (llm-buffer-append-now buffer text)
       (when code
         (ignore-errors (copy-to-clipboard-with-killring code)))
       (when (and url *llm-copilot-open-browser*
                  (not (or (uiop:getenv "SSH_CLIENT")
                           (uiop:getenv "SSH_CONNECTION")
                           (uiop:getenv "SSH_TTY")))
                  (or (uiop:getenv "DISPLAY")
                      (uiop:getenv "WAYLAND_DISPLAY")))
         (alexandria:when-let ((xdg-open (executable-find "xdg-open")))
           (ignore-errors
             (uiop:launch-program
              (list (uiop:native-namestring xdg-open) url)
              :input nil :output nil :error-output nil))))))))

(defun llm-copilot-login-form (entries)
  (format nil "~{~a~^&~}"
          (mapcar (lambda (entry)
                    (format nil "~a=~a"
                            (quri:url-encode (car entry))
                            (quri:url-encode (cdr entry))))
                  entries)))

(defun llm-copilot-login-request (url entries)
  (llm-http-json-request
   "POST" url
   '(("Accept" . "application/json")
     ("Content-Type" . "application/x-www-form-urlencoded")
     ("editor-plugin-version" . "gptel/*")
     ("editor-version" . "lem/lem-yath"))
   (llm-copilot-login-form entries)))

(defun llm-copilot-positive-integer (value fallback &optional maximum)
  (if (and (integerp value) (plusp value)
           (or (null maximum) (<= value maximum)))
      value
      fallback))

(defun llm-copilot-device-flow ()
  (let* ((device
           (llm-copilot-login-request
            *llm-copilot-device-endpoint*
            `(("client_id" . ,*llm-copilot-client-id*)
              ("scope" . "read:user"))))
         (device-code (and (hash-table-p device)
                           (gethash "device_code" device)))
         (user-code (and (hash-table-p device) (gethash "user_code" device)))
         (verification-uri
           (and (hash-table-p device) (gethash "verification_uri" device)))
         (expires-in
           (llm-copilot-positive-integer
            (and (hash-table-p device) (gethash "expires_in" device))
            900 3600))
         (interval
           (llm-copilot-positive-integer
            (and (hash-table-p device) (gethash "interval" device))
            5 60)))
    (unless (and (llm-http-token-valid-p device-code)
                 (llm-http-token-valid-p user-code)
                 (llm-http-valid-citation-p verification-uri))
      (error "GitHub returned an invalid device authorization response"))
    (llm-copilot-login-publish
     (format nil "# GitHub Copilot login~2%Visit: ~a~%Code: **~a**~2%The code was copied when clipboard access was available. Waiting for authorization…~2%"
             verification-uri user-code)
     :code user-code :url verification-uri)
    (let ((deadline (+ (get-internal-real-time)
                       (* expires-in internal-time-units-per-second))))
      (loop
        (when (>= (get-internal-real-time) deadline)
          (error "GitHub device authorization expired"))
        (sleep interval)
        (let* ((response
                 (llm-copilot-login-request
                  *llm-copilot-oauth-endpoint*
                  `(("client_id" . ,*llm-copilot-client-id*)
                    ("device_code" . ,device-code)
                    ("grant_type" . "urn:ietf:params:oauth:grant-type:device_code"))))
               (access-token
                 (and (hash-table-p response)
                      (gethash "access_token" response)))
               (oauth-error
                 (and (hash-table-p response) (gethash "error" response))))
          (cond
            ((llm-http-token-valid-p access-token)
             (llm-copilot-write-token-object
              :github (llm-json-object "access_token" access-token))
             (llm-copilot-delete-token :session)
             (return access-token))
            ((string= (or oauth-error "") "authorization_pending"))
            ((string= (or oauth-error "") "slow_down")
             (incf interval 5))
            ((string= (or oauth-error "") "access_denied")
             (error "GitHub device authorization was denied"))
            ((string= (or oauth-error "") "expired_token")
             (error "GitHub device authorization expired"))
            (t (error "GitHub device authorization failed"))))))))

(define-command lem-yath-copilot-login () ()
  "Authorize GitHub Copilot Chat with the OAuth device flow."
  (if (not (llm-copilot-login-claim))
      (message "GitHub Copilot login is already running")
      (progn
        (llm-copilot-login-publish
         (format nil "Starting GitHub device authorization…~%"))
        (bt2:make-thread
         (lambda ()
           (unwind-protect
                (handler-case
                    (progn
                      (llm-copilot-device-flow)
                      (llm-copilot-login-publish
                       (format nil
                               "Authorization complete. Copilot Chat is ready.~%")))
                  (error (condition)
                    (llm-copilot-login-publish
                     (format nil "Authorization failed: ~a~%" condition))))
             (llm-copilot-login-release)))
         :name "lem-yath/copilot-login"))))
