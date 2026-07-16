;;;; lem-yath apps/llm-oauth -- native ChatGPT Codex and Grok OAuth backends.

(in-package :lem-yath)

(defvar *llm-codex-endpoint*
  "https://chatgpt.com/backend-api/codex/responses")
(defvar *llm-codex-token-endpoint* "https://auth.openai.com/oauth/token")
(defvar *llm-codex-authorization-endpoint*
  "https://auth.openai.com/oauth/authorize")
(defvar *llm-grok-oauth-endpoint*
  "https://cli-chat-proxy.grok.com/v1/chat/completions")

(defparameter *llm-codex-client-id* "app_EMoamEEZ73f0CkXaXp7hrann")
(defparameter *llm-codex-redirect-uri*
  "http://localhost:1455/auth/callback")
(defparameter *llm-codex-login-port* 1455)
(defparameter *llm-codex-refresh-skew* 300)
(defparameter *llm-codex-login-timeout* 300)
(defparameter *llm-oauth-auth-file-limit* (* 64 1024))
(defparameter *llm-codex-instructions-prefix*
  "You are Codex, based on GPT-5. You are running as a coding agent in the Codex CLI on a user's computer.")
(defparameter *llm-codex-originator* "codex_cli_rs")
(defparameter *llm-codex-reasoning-effort* "medium")
(defparameter *llm-codex-reasoning-summary* "auto")
(defparameter *llm-grok-oauth-refresh-skew* 300)
(defparameter *llm-grok-oauth-fallback-version* "0.1.211")
(defparameter *llm-grok-oauth-executable* "grok")

(defvar *llm-codex-auto-login* t)
(defvar *llm-codex-open-browser* t)
(defvar *llm-codex-login-running-p* nil)
(defvar *llm-codex-login-lock*
  (bt2:make-lock :name "lem-yath/codex-login"))
(defvar *llm-codex-login-buffer-name* "*lem-yath-chatgpt-codex-login*")
(defvar *llm-grok-oauth-detected-version* nil)

(defparameter *llm-oauth-history-keys*
  '((:chatgpt-codex . lem-yath-llm-chatgpt-codex-history)
    (:grok-oauth . lem-yath-llm-grok-oauth-history)))
(defparameter *llm-oauth-session-keys*
  '((:chatgpt-codex . lem-yath-llm-chatgpt-codex-session-id)))
(defparameter *llm-oauth-cache-keys*
  '((:chatgpt-codex . lem-yath-llm-chatgpt-codex-prompt-cache-key)))


;;;; Private auth files

(defun llm-oauth-pathname (environment fallback)
  (uiop:parse-native-namestring
   (or (uiop:getenv environment)
       (uiop:native-namestring
        (merge-pathnames fallback (user-homedir-pathname))))))

(defun llm-codex-auth-pathname ()
  (llm-oauth-pathname "LEM_YATH_CODEX_AUTH_FILE" ".codex/auth.json"))

(defun llm-grok-oauth-auth-pathname ()
  (llm-oauth-pathname "LEM_YATH_GROK_AUTH_FILE" ".grok/auth.json"))

(defun llm-oauth-lock-pathname (pathname)
  (uiop:parse-native-namestring
   (concatenate 'string (uiop:native-namestring pathname)
                ".lem-yath.lock")))

(defun llm-oauth-prepare-parent (pathname)
  (let ((directory (uiop:pathname-directory-pathname pathname)))
    (ensure-directories-exist pathname)
    #+sbcl
    (let ((stat (sb-posix:stat (uiop:native-namestring directory))))
      (unless (and (= (logand (sb-posix:stat-mode stat) sb-posix:s-ifmt)
                      sb-posix:s-ifdir)
                   (= (sb-posix:stat-uid stat) (sb-posix:getuid))
                   (zerop (logand (sb-posix:stat-mode stat) #o022)))
        (error "OAuth credential directory must be user-owned and not writable by others")))
    #-sbcl (error "Safe OAuth credential access requires SBCL")
    directory))

(defun llm-oauth-read-json-file (pathname &key required)
  "Read one private, regular, user-owned JSON PATHNAME through a descriptor."
  (unless (uiop:file-exists-p pathname)
    (when required (error "OAuth credential file is missing"))
    (return-from llm-oauth-read-json-file nil))
  #+sbcl
  (let ((descriptor nil)
        (stream nil))
    (unwind-protect
         (progn
           (setf descriptor
                 (sb-posix:open
                  (uiop:native-namestring pathname)
                  (logior sb-posix:o-rdonly sb-posix:o-nofollow)))
           (let* ((stat (sb-posix:fstat descriptor))
                  (length (sb-posix:stat-size stat)))
             (unless (and (= (logand (sb-posix:stat-mode stat) sb-posix:s-ifmt)
                             sb-posix:s-ifreg)
                          (= (sb-posix:stat-uid stat) (sb-posix:getuid))
                          (zerop (logand (sb-posix:stat-mode stat) #o077)))
               (error "OAuth credential file must be private, regular, and user-owned"))
             (when (> length *llm-oauth-auth-file-limit*)
               (error "OAuth credential file exceeds the size limit"))
             (setf stream
                   (sb-sys:make-fd-stream
                    descriptor :input t :element-type '(unsigned-byte 8)
                    :buffering :full
                    :name (uiop:native-namestring pathname)))
             (setf descriptor nil)
             (let ((octets (make-array length :element-type '(unsigned-byte 8))))
               (unless (= length (read-sequence octets stream))
                 (error "Could not read the complete OAuth credential file"))
               (handler-case
                   (yason:parse
                    (sb-ext:octets-to-string octets :external-format :utf-8))
                 (error ()
                   (error "OAuth credential file contains malformed JSON"))))))
      (when stream (ignore-errors (close stream :abort t)))
      (when descriptor (ignore-errors (sb-posix:close descriptor)))))
  #-sbcl
  (declare (ignore pathname required))
  #-sbcl (error "Safe OAuth credential access requires SBCL"))

(defun llm-oauth-temporary-pathname (pathname)
  (uiop:parse-native-namestring
   (format nil "~a.tmp.~d.~a"
           (uiop:native-namestring pathname)
           #+sbcl (sb-posix:getpid)
           #-sbcl 0
           (llm-http-random-hex 16))))

(defun llm-oauth-write-json-file (pathname object)
  "Atomically write OBJECT to private JSON PATHNAME."
  (llm-oauth-prepare-parent pathname)
  (let* ((temporary (llm-oauth-temporary-pathname pathname))
         (text (with-output-to-string (stream) (yason:encode object stream)))
         (octets #+sbcl (sb-ext:string-to-octets
                         text :external-format :utf-8)
                 #-sbcl (error "UTF-8 OAuth encoding requires SBCL"))
         (descriptor nil)
         (stream nil))
    (when (> (length octets) *llm-oauth-auth-file-limit*)
      (error "Refusing an oversized OAuth credential object"))
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
           #-sbcl (error "Safe OAuth credential persistence requires SBCL")
           (uiop:rename-file-overwriting-target temporary pathname)
           #+sbcl (sb-posix:chmod (uiop:native-namestring pathname) #o600)
           object)
      (when stream
        (ignore-errors (close stream :abort t))
        (setf descriptor nil))
      (when descriptor (ignore-errors (sb-posix:close descriptor)))
      (when (uiop:file-exists-p temporary)
        (ignore-errors (delete-file temporary))))))

(defun call-with-llm-oauth-file-lock (pathname function)
  "Call FUNCTION while holding Lem's cross-process lock for PATHNAME."
  (llm-oauth-prepare-parent pathname)
  #+sbcl
  (let* ((lock-pathname (llm-oauth-lock-pathname pathname))
         (descriptor
           (sb-posix:open
            (uiop:native-namestring lock-pathname)
            (logior sb-posix:o-creat sb-posix:o-rdwr sb-posix:o-nofollow)
            #o600)))
    (unwind-protect
         (progn
           (sb-posix:fchmod descriptor #o600)
           (let ((stat (sb-posix:fstat descriptor)))
             (unless (and (= (logand (sb-posix:stat-mode stat) sb-posix:s-ifmt)
                             sb-posix:s-ifreg)
                          (= (sb-posix:stat-uid stat) (sb-posix:getuid)))
               (error "OAuth credential lock must be a regular user-owned file")))
           (sb-posix:lockf descriptor sb-posix:f-lock 0)
           (funcall function))
      (ignore-errors (sb-posix:lockf descriptor sb-posix:f-ulock 0))
      (ignore-errors (sb-posix:close descriptor))))
  #-sbcl
  (declare (ignore pathname function))
  #-sbcl (error "Safe OAuth credential locking requires SBCL"))


;;;; Encoding and token helpers

(defun llm-oauth-random-octets (count)
  (let ((octets (make-array count :element-type '(unsigned-byte 8))))
    (with-open-file (stream #P"/dev/urandom" :element-type '(unsigned-byte 8))
      (unless (= count (read-sequence octets stream))
        (error "Could not read secure random bytes")))
    octets))

(defun llm-oauth-base64url-encode (octets)
  (let ((alphabet
          "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"))
    (with-output-to-string (stream)
      (loop :for index :from 0 :below (length octets) :by 3
            :for remaining := (- (length octets) index)
            :for first := (aref octets index)
            :for second := (if (> remaining 1) (aref octets (1+ index)) 0)
            :for third := (if (> remaining 2) (aref octets (+ index 2)) 0)
            :for value := (logior (ash first 16) (ash second 8) third)
            :do (write-char (char alphabet (ldb (byte 6 18) value)) stream)
                (write-char (char alphabet (ldb (byte 6 12) value)) stream)
                (when (> remaining 1)
                  (write-char (char alphabet (ldb (byte 6 6) value)) stream))
                (when (> remaining 2)
                  (write-char (char alphabet (ldb (byte 6 0) value)) stream))))))

(defun llm-oauth-base64url-value (character)
  (cond
    ((char<= #\A character #\Z) (- (char-code character) (char-code #\A)))
    ((char<= #\a character #\z) (+ 26 (- (char-code character) (char-code #\a))))
    ((char<= #\0 character #\9) (+ 52 (- (char-code character) (char-code #\0))))
    ((char= character #\-) 62)
    ((char= character #\_) 63)
    (t nil)))

(defun llm-oauth-base64url-decode (text)
  (when (> (length text) 32768)
    (error "Encoded token component exceeds the size limit"))
  (let ((octets (make-array 0 :element-type '(unsigned-byte 8)
                              :adjustable t :fill-pointer 0))
        (bits 0)
        (accumulator 0))
    (loop :for character :across text
          :unless (char= character #\=)
            :do (let ((value (llm-oauth-base64url-value character)))
                  (unless value (error "Invalid base64url data"))
                  (setf accumulator (logior (ash accumulator 6) value)
                        bits (+ bits 6))
                  (when (>= bits 8)
                    (decf bits 8)
                    (vector-push-extend (ldb (byte 8 bits) accumulator) octets)
                    (setf accumulator
                          (if (zerop bits)
                              0
                              (logand accumulator (1- (ash 1 bits))))))))
    octets))

(defun llm-oauth-jwt-payload (token)
  (unless (and (llm-http-token-valid-p token)
               (<= (length token) 32768))
    (error "Invalid OAuth access token"))
  (let* ((parts (uiop:split-string token :separator '(#\.)))
         (encoded (second parts)))
    (unless (= (length parts) 3) (error "Invalid JWT"))
    (handler-case
        (yason:parse
         #+sbcl
         (sb-ext:octets-to-string
          (llm-oauth-base64url-decode encoded) :external-format :utf-8)
         #-sbcl (error "JWT decoding requires SBCL"))
      (error () (error "Invalid JWT payload")))))

(defun llm-oauth-jwt-expiry (token)
  (let ((expiry (gethash "exp" (llm-oauth-jwt-payload token))))
    (unless (integerp expiry) (error "JWT has no numeric expiry"))
    expiry))

(defun llm-codex-account-id-from-token (id-token)
  (let* ((payload (llm-oauth-jwt-payload id-token))
         (auth (gethash "https://api.openai.com/auth" payload))
         (account (and (hash-table-p auth)
                       (gethash "chatgpt_account_id" auth))))
    (and (llm-http-token-valid-p account) account)))

(defun llm-oauth-sha256 (text)
  "Return SHA-256(TEXT) as octets without placing TEXT in argv."
  (let ((executable (or (executable-find "sha256sum")
                        (error "sha256sum is unavailable")))
        (*project-process-timeout* 10))
    (multiple-value-bind (output error-output status)
        (run-project-program
         (list (uiop:native-namestring executable))
         :input text :output-limit 1024)
      (declare (ignore error-output))
      (unless (and (integerp status) (zerop status) (>= (length output) 64))
        (error "Could not calculate the PKCE challenge"))
      (let ((octets (make-array 32 :element-type '(unsigned-byte 8))))
        (loop :for index :below 32
              :for start := (* index 2)
              :for value := (parse-integer output :start start :end (+ start 2)
                                      :radix 16 :junk-allowed nil)
              :do (setf (aref octets index) value))
        octets))))

(defun llm-oauth-form (entries)
  (format nil "~{~a~^&~}"
          (mapcar (lambda (entry)
                    (format nil "~a=~a"
                            (quri:url-encode (car entry))
                            (quri:url-encode (cdr entry))))
                  entries)))

(defun llm-oauth-now-string ()
  (multiple-value-bind (second minute hour day month year)
      (decode-universal-time (get-universal-time) 0)
    (format nil "~4,'0d-~2,'0d-~2,'0dT~2,'0d:~2,'0d:~2,'0d.000Z"
            year month day hour minute second)))

(defun llm-oauth-json-text (object)
  (with-output-to-string (stream) (yason:encode object stream)))


;;;; ChatGPT Codex auth

(defun llm-codex-token-object (auth)
  (and (hash-table-p auth) (gethash "tokens" auth)))

(defun llm-codex-auth-valid-p (auth)
  (let ((tokens (llm-codex-token-object auth)))
    (and (hash-table-p tokens)
         (llm-http-token-valid-p (gethash "access_token" tokens))
         (llm-http-token-valid-p (gethash "refresh_token" tokens)))))

(defun llm-codex-auth-needs-refresh-p (auth)
  (handler-case
      (<= (llm-oauth-jwt-expiry
           (gethash "access_token" (llm-codex-token-object auth)))
          (+ (llm-http-unix-time) *llm-codex-refresh-skew*))
    (error () t)))

(defun llm-codex-refresh-response (refresh-token)
  (llm-http-json-request
   "POST" *llm-codex-token-endpoint*
   '(("Content-Type" . "application/x-www-form-urlencoded")
     ("Accept" . "application/json"))
   (llm-oauth-form
    `(("grant_type" . "refresh_token")
      ("refresh_token" . ,refresh-token)
      ("client_id" . ,*llm-codex-client-id*)
      ("scope" . "openid profile email offline_access")))))

(defun llm-codex-apply-token-response (auth response)
  (unless (and (hash-table-p response)
               (llm-http-token-valid-p (gethash "access_token" response)))
    (error "ChatGPT Codex returned an invalid token refresh"))
  (let* ((result (or auth (make-hash-table :test #'equal)))
         (tokens (or (llm-codex-token-object result)
                     (make-hash-table :test #'equal)))
         (id-token (or (gethash "id_token" response)
                       (gethash "id_token" tokens)))
         (refresh-token (or (gethash "refresh_token" response)
                            (gethash "refresh_token" tokens)))
         (account-id (or (and id-token
                              (ignore-errors
                                (llm-codex-account-id-from-token id-token)))
                         (gethash "account_id" tokens))))
    (unless (and (llm-http-token-valid-p refresh-token)
                 (llm-http-token-valid-p account-id))
      (error "ChatGPT Codex token response lacks refresh or account data"))
    (setf (gethash "access_token" tokens) (gethash "access_token" response)
          (gethash "refresh_token" tokens) refresh-token
          (gethash "account_id" tokens) account-id)
    (when id-token (setf (gethash "id_token" tokens) id-token))
    (setf (gethash "tokens" result) tokens
          (gethash "last_refresh" result) (llm-oauth-now-string))
    result))

(defun llm-codex-refresh-auth (&optional force)
  (let ((pathname (llm-codex-auth-pathname)))
    (call-with-llm-oauth-file-lock
     pathname
     (lambda ()
       (let ((auth (llm-oauth-read-json-file pathname :required t)))
         (unless (llm-codex-auth-valid-p auth)
           (error "ChatGPT Codex auth is invalid; run M-x lem-yath-chatgpt-codex-login"))
         (if (and (not force) (not (llm-codex-auth-needs-refresh-p auth)))
             auth
             (let* ((tokens (llm-codex-token-object auth))
                    (response
                      (llm-codex-refresh-response
                       (gethash "refresh_token" tokens)))
                    (updated (llm-codex-apply-token-response auth response)))
               (llm-oauth-write-json-file pathname updated))))))))

(defun llm-codex-ensure-auth (&key force-refresh)
  (let* ((pathname (llm-codex-auth-pathname))
         (auth (llm-oauth-read-json-file pathname)))
    (unless (llm-codex-auth-valid-p auth)
      (if *llm-codex-auto-login*
          (progn
            (llm-codex-login-synchronously)
            (setf auth (llm-oauth-read-json-file pathname :required t)))
          (error "ChatGPT Codex auth is unavailable; run M-x lem-yath-chatgpt-codex-login")))
    (if (or force-refresh (llm-codex-auth-needs-refresh-p auth))
        (handler-case
            (llm-codex-refresh-auth force-refresh)
          (error (condition)
            (if *llm-codex-auto-login*
                (progn
                  (llm-codex-login-synchronously)
                  (llm-oauth-read-json-file pathname :required t))
                (error condition))))
        auth)))

(defun llm-codex-user-agent ()
  (format nil "codex_cli_rs/0.115.0 (~a; ~a)"
          (or (software-type) "Linux")
          (or (machine-type) "unknown")))

(defun llm-codex-headers (auth session-id)
  (let* ((tokens (llm-codex-token-object auth))
         (access-token (and tokens (gethash "access_token" tokens)))
         (account-id (and tokens (gethash "account_id" tokens))))
    (unless (and (llm-http-token-valid-p access-token)
                 (llm-http-token-valid-p account-id))
      (error "ChatGPT Codex auth lacks access or account data"))
    `(("Authorization" . ,(format nil "Bearer ~a" access-token))
      ("chatgpt-account-id" . ,account-id)
      ("Content-Type" . "application/json")
      ("Accept" . "text/event-stream")
      ("OpenAI-Beta" . "responses=experimental")
      ("originator" . ,*llm-codex-originator*)
      ("User-Agent" . ,(llm-codex-user-agent))
      ("session_id" . ,session-id))))


;;;; Grok OAuth auth

(defun llm-grok-oauth-credential (&optional auth)
  (let ((object (or auth
                    (llm-oauth-read-json-file
                     (llm-grok-oauth-auth-pathname)))))
    (when (hash-table-p object)
      (loop :for scope :being :the :hash-keys :of object
              :using (hash-value credential)
            :when (and (hash-table-p credential)
                       (llm-http-token-valid-p (gethash "key" credential)))
              :return (list :scope scope
                            :key (gethash "key" credential)
                            :user-id (gethash "user_id" credential)
                            :expires-at (gethash "expires_at" credential))))))

(defun llm-oauth-rfc3339-universal-time (text)
  "Parse the UTC subset used by the official Grok auth file."
  (unless (and (stringp text) (>= (length text) 20)
               (char= (char text 4) #\-)
               (char= (char text 7) #\-)
               (char= (char text 10) #\T)
               (char= (char text 13) #\:)
               (char= (char text 16) #\:)
               (or (char= (char text (1- (length text))) #\Z)
                   (string= "+00:00" text :start2 (- (length text) 6))))
    (error "Invalid OAuth expiry timestamp"))
  (handler-case
      (encode-universal-time
       (parse-integer text :start 17 :end 19)
       (parse-integer text :start 14 :end 16)
       (parse-integer text :start 11 :end 13)
       (parse-integer text :start 8 :end 10)
       (parse-integer text :start 5 :end 7)
       (parse-integer text :start 0 :end 4)
       0)
    (error () (error "Invalid OAuth expiry timestamp"))))

(defun llm-grok-oauth-expiring-p (credential)
  (let ((expires-at (getf credential :expires-at)))
    (and expires-at
         (<= (llm-oauth-rfc3339-universal-time expires-at)
             (+ (get-universal-time) *llm-grok-oauth-refresh-skew*)))))

(defun llm-grok-oauth-run-cli (argument)
  (let ((executable (or (executable-find *llm-grok-oauth-executable*)
                        (error "grok CLI is unavailable; run grok login --oauth on this host")))
        (*project-process-timeout* 30))
    (run-project-program
     (list (uiop:native-namestring executable) argument)
     :output-limit (* 1024 1024))))

(defun llm-grok-oauth-refresh ()
  (multiple-value-bind (output error-output status)
      (llm-grok-oauth-run-cli "models")
    (declare (ignore output error-output))
    (unless (and (integerp status) (zerop status))
      (error "Grok OAuth refresh failed"))))

(defun llm-grok-oauth-ensure-credential (&key force-refresh)
  (let ((credential (llm-grok-oauth-credential)))
    (when (and credential
               (or force-refresh (llm-grok-oauth-expiring-p credential)))
      (llm-grok-oauth-refresh)
      (setf credential (llm-grok-oauth-credential)))
    (unless (and credential (llm-http-token-valid-p (getf credential :key)))
      (error "Grok OAuth auth is unavailable; run grok login --oauth"))
    (when (llm-grok-oauth-expiring-p credential)
      (error "Grok OAuth credential remains expired after refresh"))
    credential))

(defun llm-grok-oauth-version-token-p (token)
  (and (plusp (length token))
       (digit-char-p (char token 0))
       (every (lambda (character)
                (or (digit-char-p character) (char= character #\.)))
              token)
       (find #\. token)))

(defun llm-grok-oauth-client-version ()
  (or *llm-grok-oauth-detected-version*
      (setf *llm-grok-oauth-detected-version*
            (handler-case
                (multiple-value-bind (output error-output status)
                    (llm-grok-oauth-run-cli "version")
                  (declare (ignore error-output))
                  (if (and (integerp status) (zerop status))
                      (or (find-if #'llm-grok-oauth-version-token-p
                                   (uiop:split-string
                                    (string-trim '(#\Space #\Tab #\Newline #\Return)
                                                 output)
                                    :separator '(#\Space #\Tab #\Newline #\Return)))
                          *llm-grok-oauth-fallback-version*)
                      *llm-grok-oauth-fallback-version*))
              (error () *llm-grok-oauth-fallback-version*)))))

(defun llm-grok-oauth-headers (credential model)
  (let ((version (llm-grok-oauth-client-version))
        (token (getf credential :key))
        (user-id (getf credential :user-id)))
    (append
     `(("Content-Type" . "application/json")
       ("Accept" . "text/event-stream")
       ("Authorization" . ,(format nil "Bearer ~a" token))
       ("X-XAI-Token-Auth" . "xai-grok-cli")
       ("x-grok-client-version" . ,version)
       ("x-grok-client-identifier" . "grok-shell")
       ("x-grok-model-override" . ,model)
       ("User-Agent" . ,(format nil "grok-shell/~a (linux; ~a)"
                                version (or (machine-type) "unknown"))))
     (when (llm-http-token-valid-p user-id)
       `(("x-grok-user-id" . ,user-id))))))


;;;; Conversation state and shared transport

(defun llm-oauth-history-key (backend)
  (or (cdr (assoc backend *llm-oauth-history-keys*))
      (error "No OAuth history key for ~s" backend)))

(defun llm-oauth-history (backend buffer)
  (copy-list (or (buffer-value buffer (llm-oauth-history-key backend)) nil)))

(defun llm-oauth-publish-history (request backend history)
  (send-event
   (lambda ()
     (when (llm-request-current-p request)
       (setf (buffer-value (llm-request-buffer request)
                           (llm-oauth-history-key backend))
             history)))))

(defun llm-oauth-secure-uuid ()
  (let ((octets (llm-oauth-random-octets 16)))
    (setf (aref octets 6) (logior #x40 (logand #x0f (aref octets 6)))
          (aref octets 8) (logior #x80 (logand #x3f (aref octets 8))))
    (let ((hex
            (string-downcase
             (with-output-to-string (stream)
               (loop :for byte :across octets
                     :do (format stream "~2,'0x" byte))))))
      (format nil "~a-~a-~a-~a-~a"
              (subseq hex 0 8) (subseq hex 8 12)
              (subseq hex 12 16) (subseq hex 16 20)
              (subseq hex 20 32)))))

(defun llm-oauth-buffer-id (buffer table)
  (let* ((key (cdr (assoc :chatgpt-codex table)))
         (existing (and key (buffer-value buffer key))))
    (or (and (llm-cli-session-id-valid-p existing) existing)
        (let ((created (llm-oauth-secure-uuid)))
          (setf (buffer-value buffer key) created)
          created))))

(defun llm-oauth-clear-session (backend &optional (buffer (llm-output-buffer)))
  (when (assoc backend *llm-oauth-history-keys*)
    (setf (buffer-value buffer (llm-oauth-history-key backend)) nil)
    (dolist (table (list *llm-oauth-session-keys* *llm-oauth-cache-keys*))
      (alexandria:when-let ((key (cdr (assoc backend table))))
        (setf (buffer-value buffer key) nil)))
    t))

(defun llm-oauth-stream-round (request provider url headers body reader)
  (let ((process
          (llm-http-launch-stream "POST" url headers body :status-p t))
        (finished-p nil))
    (unless (llm-request-install-process request process)
      (ignore-errors (uiop:terminate-process process :urgent t))
      (ignore-errors (uiop:wait-process process))
      (return-from llm-oauth-stream-round (values nil nil nil)))
    (unwind-protect
         (multiple-value-bind (round http-status)
             (funcall reader request process provider)
           (let ((process-status (uiop:wait-process process)))
             (setf finished-p t)
             (values round http-status process-status)))
      (unless finished-p
        (ignore-errors (uiop:terminate-process process :urgent t))
        (ignore-errors (uiop:wait-process process)))
      (llm-request-release-process request process))))

(defun llm-oauth-chat-reader (request process provider)
  (llm-read-chat-completions-round request process provider))

(defun llm-oauth-effective-status (http-status process-status)
  (or http-status
      (and (integerp process-status) (zerop process-status) 200)))


;;;; Grok chat-completions tool loop

(defun llm-grok-oauth-loop
    (request messages model temperature max-tokens tools)
  (let ((tool-rounds 0)
        (tool-calls 0)
        (retried-auth-p nil))
    (loop
      (when (llm-request-aborted-now-p request) (return))
      (catch 'llm-grok-retry
        (handler-case
          (let* ((credential (llm-grok-oauth-ensure-credential))
                 (headers (llm-grok-oauth-headers credential model))
                 (body (llm-request-body-for-messages
                        messages model temperature max-tokens tools)))
            (multiple-value-bind (round http-status process-status)
                (llm-oauth-stream-round
                 request "Grok OAuth" *llm-grok-oauth-endpoint*
                 headers body #'llm-oauth-chat-reader)
              (when (llm-request-aborted-now-p request) (return))
              (let ((status
                      (llm-oauth-effective-status http-status process-status)))
                (when (and (= (or status 0) 401) (not retried-auth-p))
                  (llm-grok-oauth-ensure-credential :force-refresh t)
                  (setf retried-auth-p t)
                  (throw 'llm-grok-retry nil))
                (unless (and round (= (or status 0) 200)
                             (integerp process-status) (zerop process-status))
                  (llm-request-finish
                   request
                   (format nil "~%[Grok OAuth request failed, HTTP ~a, exit ~a]~%"
                           (or status "unknown") process-status))
                  (return))
                (setf retried-auth-p nil)
                (let ((calls (llm-stream-round-tool-calls round)))
                  (when (null calls)
                    (let ((content (llm-stream-round-content round)))
                      (setf messages
                            (append messages
                                    (list (llm-json-object
                                           "role" "assistant"
                                           "content" content))))
                      (llm-oauth-publish-history
                       request :grok-oauth messages)
                      (llm-request-finish request (string #\Newline)))
                    (return))
                  (unless tools
                    (error "Grok OAuth requested tools from a tool-free preset"))
                  (when (>= tool-rounds *llm-max-tool-rounds*)
                    (error "LLM tool round limit reached"))
                  (when (> (+ tool-calls (length calls))
                           *llm-max-tool-calls-per-request*)
                    (error "LLM tool call limit reached"))
                  (incf tool-rounds)
                  (incf tool-calls (length calls))
                  (let ((tool-messages
                          (llm-execute-stream-tool-calls request round)))
                    (when (llm-request-aborted-now-p request) (return))
                    (setf messages (append messages tool-messages))
                    (llm-request-append
                     request (format nil "~%### Assistant (continued)~2%")))))))
        (error (condition)
          (unless (llm-request-aborted-now-p request)
            (llm-request-finish
             request (format nil "~%[Grok OAuth protocol error: ~a]~%"
                             condition)))
          (return)))))))


;;;; ChatGPT Codex Responses API

(defun llm-codex-message-item (role text)
  (llm-json-object
   "type" "message" "role" role
   "content"
   (vector (llm-json-object
            "type" (if (string= role "assistant")
                        "output_text" "input_text")
            "text" text))))

(defun llm-codex-tool-definitions (chat-tools)
  (coerce
   (loop :for tool :across chat-tools
         :for function := (and (hash-table-p tool) (gethash "function" tool))
         :when (hash-table-p function)
           :collect
           (let ((parameters (gethash "parameters" function)))
             (llm-json-object
              "type" "function"
              "name" (gethash "name" function)
              "description" (gethash "description" function)
              "parameters"
              (if (hash-table-p parameters)
                  (llm-json-object
                   "type" (or (gethash "type" parameters) "object")
                   "properties" (or (gethash "properties" parameters)
                                    (llm-json-object))
                   "required" (or (gethash "required" parameters) #())
                   "additionalProperties" yason:false)
                  (llm-json-object
                   "type" "object" "properties" (llm-json-object)
                   "required" #() "additionalProperties" yason:false)))))
   'vector))

(defun llm-codex-instructions (system)
  (let ((extra (string-trim '(#\Space #\Tab #\Newline #\Return)
                            (or system ""))))
    (cond
      ((zerop (length extra)) *llm-codex-instructions-prefix*)
      ((and (>= (length extra) (length *llm-codex-instructions-prefix*))
            (string= extra *llm-codex-instructions-prefix*
                     :end1 (length *llm-codex-instructions-prefix*)))
       extra)
      (t (format nil "~a~2%~a" *llm-codex-instructions-prefix* extra)))))

(defun llm-codex-request-body
    (input model system temperature max-tokens tools prompt-cache-key)
  (let ((body
          (llm-json-object
           "model" model
           "instructions" (llm-codex-instructions system)
           "input" (coerce input 'vector)
           "store" yason:false
           "stream" t
           "parallel_tool_calls" (if tools t yason:false)
           "reasoning"
           (llm-json-object
            "effort" *llm-codex-reasoning-effort*
            "summary" *llm-codex-reasoning-summary*)
           "prompt_cache_key" prompt-cache-key)))
    (when temperature (setf (gethash "temperature" body) temperature))
    (when max-tokens (setf (gethash "max_output_tokens" body) max-tokens))
    (when tools
      (setf (gethash "tools" body) (llm-codex-tool-definitions tools)))
    (llm-oauth-json-text body)))

(defun llm-codex-stream-call (table item &optional output-index)
  (let* ((item-id (or (gethash "id" item) (gethash "call_id" item)))
         (call-id (or (gethash "call_id" item) item-id))
         (index (if (and (integerp output-index) (<= 0 output-index))
                    output-index
                    (hash-table-count table))))
    (unless (and (llm-http-token-valid-p item-id)
                 (<= (length item-id) 256)
                 (llm-http-token-valid-p call-id)
                 (<= (length call-id) 256)
                 (< index *llm-max-tool-calls-per-round*))
      (error "ChatGPT Codex emitted an invalid function call"))
    (let ((call (or (gethash item-id table)
                    (setf (gethash item-id table)
                          (make-llm-stream-tool-call index)))))
      (when call-id (setf (llm-stream-tool-call-id call) call-id))
      (alexandria:when-let ((name (gethash "name" item)))
        (unless (and (stringp name) (<= (length name) 128))
          (error "ChatGPT Codex emitted an invalid function name"))
        (setf (llm-stream-tool-call-name call) name))
      (alexandria:when-let ((arguments (gethash "arguments" item)))
        (unless (and (stringp arguments)
                     (<= (length arguments)
                         *llm-tool-argument-character-limit*))
          (error "ChatGPT Codex emitted oversized function arguments"))
        (setf (llm-stream-tool-call-arguments call) arguments))
      call)))

(defun llm-codex-event-error (json)
  (let ((error (and (hash-table-p json) (gethash "error" json))))
    (or (and (hash-table-p error) (gethash "message" error))
        (and (hash-table-p json) (gethash "message" json))
        "ChatGPT Codex request failed")))

(defun llm-codex-apply-event
    (request event json content calls content-count)
  (cond
    ((string= event "response.output_text.delta")
     (let ((chunk (gethash "delta" json)))
       (when (stringp chunk)
         (incf content-count (length chunk))
         (when (> content-count *llm-response-character-limit*)
           (error "ChatGPT Codex response exceeded the size limit"))
         (write-string chunk content)
         (llm-request-append request chunk))))
    ((string= event "response.output_item.added")
     (let ((item (gethash "item" json)))
       (when (and (hash-table-p item)
                  (string= (or (gethash "type" item) "") "function_call"))
         (llm-codex-stream-call calls item (gethash "output_index" json)))))
    ((string= event "response.function_call_arguments.delta")
     (let* ((item-id (or (gethash "item_id" json)
                         (gethash "output_item_id" json)))
            (call (and item-id (gethash item-id calls)))
            (delta (gethash "delta" json)))
       (when (and call (stringp delta))
         (setf (llm-stream-tool-call-arguments call)
               (llm-bounded-fragment
                (llm-stream-tool-call-arguments call) delta
                *llm-tool-argument-character-limit* "tool arguments")))))
    ((or (string= event "response.function_call_arguments.done")
         (string= event "response.function_call.completed")
         (string= event "response.output_item.done"))
     (let ((item (gethash "item" json)))
       (when (and (hash-table-p item)
                  (string= (or (gethash "type" item) "") "function_call"))
         (llm-codex-stream-call calls item (gethash "output_index" json)))))
    ((or (string= event "response.error")
         (string= event "response.failed"))
     (error "~a" (llm-codex-event-error json))))
  content-count)

(defun llm-codex-read-responses-round (request process provider)
  (declare (ignore provider))
  (let ((content (make-string-output-stream))
        (content-count 0)
        (calls (make-hash-table :test #'equal))
        (event nil)
        (http-status nil)
        (done-p nil)
        (*llm-stream-provider-name* "ChatGPT Codex"))
    (with-open-stream (output (uiop:process-info-output process))
      (loop :for line := (read-line output nil)
            :while line
            :do
               (cond
                 ((and (>= (length line) 25)
                       (string= line "__LEM_YATH_HTTP_STATUS__:" :end1 25
                                                                 :end2 25))
                  (let ((value (subseq line 25)))
                    (when (and (= (length value) 3)
                               (every #'digit-char-p value))
                      (setf http-status (parse-integer value)))))
                 ((zerop (length line)) (setf event nil))
                 ((and (>= (length line) 6)
                       (string= line "event:" :end1 6 :end2 6))
                  (setf event
                        (string-trim '(#\Space #\Tab) (subseq line 6))))
                 ((and (not done-p) (>= (length line) 5)
                       (string= line "data:" :end1 5 :end2 5))
                  (let ((payload
                          (string-left-trim '(#\Space #\Tab) (subseq line 5))))
                    (if (string= payload "[DONE]")
                        (setf done-p t)
                        (let* ((json
                                 (handler-case (yason:parse payload)
                                   (error ()
                                     (error "ChatGPT Codex emitted malformed SSE JSON"))))
                               (kind (or event
                                         (and (hash-table-p json)
                                              (gethash "type" json)))))
                          (when (and (stringp kind) (hash-table-p json))
                            (setf content-count
                                  (llm-codex-apply-event
                                   request kind json content calls
                                   content-count)))))))))
    (values
     (make-llm-stream-round
      :content (get-output-stream-string content)
      :tool-calls (llm-finalize-stream-tool-calls calls)
      :finish-reason (if (plusp (hash-table-count calls))
                         "tool_calls" "stop"))
     http-status))))

(defun llm-codex-function-call-item (call)
  (llm-json-object
   "type" "function_call"
   "call_id" (llm-stream-tool-call-id call)
   "name" (llm-stream-tool-call-name call)
   "arguments" (llm-stream-tool-call-arguments call)))

(defun llm-codex-execute-tool-calls (request round)
  (let ((items nil)
        (content (llm-stream-round-content round)))
    (when (plusp (length content))
      (setf items (list (llm-codex-message-item "assistant" content))))
    (dolist (call (llm-stream-round-tool-calls round) items)
      (when (llm-request-aborted-now-p request)
        (return-from llm-codex-execute-tool-calls nil))
      (let ((result
              (llm-invoke-tool
               (llm-request-tool-context request)
               (llm-stream-tool-call-name call)
               (llm-stream-tool-call-arguments call))))
        (llm-render-tool-result request call result)
        (setf items
              (append items
                      (list
                       (llm-codex-function-call-item call)
                       (llm-json-object
                        "type" "function_call_output"
                        "call_id" (llm-stream-tool-call-id call)
                        "output" result))))))))

(defun llm-codex-loop
    (request input model system temperature max-tokens tools session-id cache-key)
  (let ((tool-rounds 0)
        (tool-calls 0)
        (retried-auth-p nil))
    (loop
      (when (llm-request-aborted-now-p request) (return))
      (catch 'llm-codex-retry
        (handler-case
          (let* ((auth (llm-codex-ensure-auth))
                 (headers (llm-codex-headers auth session-id))
                 (body (llm-codex-request-body
                        input model system temperature max-tokens tools cache-key)))
            (multiple-value-bind (round http-status process-status)
                (llm-oauth-stream-round
                 request "ChatGPT Codex" *llm-codex-endpoint*
                 headers body #'llm-codex-read-responses-round)
              (when (llm-request-aborted-now-p request) (return))
              (let ((status
                      (llm-oauth-effective-status http-status process-status)))
                (when (and (= (or status 0) 401) (not retried-auth-p))
                  (llm-codex-ensure-auth :force-refresh t)
                  (setf retried-auth-p t)
                  (throw 'llm-codex-retry nil))
                (unless (and round (= (or status 0) 200)
                             (integerp process-status) (zerop process-status))
                  (llm-request-finish
                   request
                   (format nil "~%[ChatGPT Codex request failed, HTTP ~a, exit ~a]~%"
                           (or status "unknown") process-status))
                  (return))
                (setf retried-auth-p nil)
                (let ((calls (llm-stream-round-tool-calls round)))
                  (when (null calls)
                    (setf input
                          (append input
                                  (list (llm-codex-message-item
                                         "assistant"
                                         (llm-stream-round-content round)))))
                    (llm-oauth-publish-history request :chatgpt-codex input)
                    (llm-request-finish request (string #\Newline))
                    (return))
                  (unless tools
                    (error "ChatGPT Codex requested tools from a tool-free preset"))
                  (when (>= tool-rounds *llm-max-tool-rounds*)
                    (error "LLM tool round limit reached"))
                  (when (> (+ tool-calls (length calls))
                           *llm-max-tool-calls-per-request*)
                    (error "LLM tool call limit reached"))
                  (incf tool-rounds)
                  (incf tool-calls (length calls))
                  (let ((tool-items
                          (llm-codex-execute-tool-calls request round)))
                    (when (llm-request-aborted-now-p request) (return))
                    (setf input (append input tool-items))
                    (llm-request-append
                     request (format nil "~%### Assistant (continued)~2%")))))))
        (error (condition)
          (unless (llm-request-aborted-now-p request)
            (llm-request-finish
             request (format nil "~%[ChatGPT Codex protocol error: ~a]~%"
                             condition)))
          (return)))))))


;;;; Entry points

(defun llm-oauth-stream (backend prompt)
  (let ((buffer (llm-output-buffer))
        (model *llm-model*)
        (system *llm-system-message*)
        (temperature *llm-temperature*)
        (max-tokens *llm-max-tokens*)
        (tools-p *llm-use-tools*))
    (when (llm-active-request buffer)
      (message "An LLM request is already running; use M-x lem-yath-llm-abort")
      (return-from llm-oauth-stream))
    (let ((tool-context
            (when tools-p
              (handler-case (llm-capture-tool-context)
                (error ()
                  (message "Could not capture the LLM project context")
                  (return-from llm-oauth-stream))))))
      (let* ((insertion-point
               (llm-prepare-response
                buffer
                (format nil "~%## User (~a / ~a)~%~%~a~%~%## Assistant~%~%"
                        (ecase backend
                          (:chatgpt-codex "ChatGPT Codex")
                          (:grok-oauth "Grok OAuth"))
                        model prompt)))
             (history (llm-oauth-history backend buffer))
             (messages
               (ecase backend
                 (:chatgpt-codex
                  (append history
                          (list (llm-codex-message-item "user" prompt))))
                 (:grok-oauth
                  (append (or history
                              (list (llm-json-object
                                     "role" "system" "content" system)))
                          (list (llm-json-object
                                 "role" "user" "content" prompt))))))
             (session-id
               (and (eq backend :chatgpt-codex)
                    (llm-oauth-buffer-id buffer *llm-oauth-session-keys*)))
             (cache-key
               (and (eq backend :chatgpt-codex)
                    (llm-oauth-buffer-id buffer *llm-oauth-cache-keys*)))
             (request
               (llm-register-request
                buffer nil backend :insertion-point insertion-point
                :tool-context tool-context :tools-p tools-p)))
        (llm-start-request-thread
         request
         (lambda ()
           (unwind-protect
                (handler-case
                    (let ((tools (and tools-p (llm-tool-definitions))))
                      (ecase backend
                        (:chatgpt-codex
                         (llm-codex-loop
                          request messages model system temperature max-tokens
                          tools session-id cache-key))
                        (:grok-oauth
                         (llm-grok-oauth-loop
                          request messages model temperature max-tokens tools))))
                  (error (condition)
                    (unless (llm-request-aborted-now-p request)
                      (llm-request-finish
                       request
                       (format nil "~%[~:(~a~) backend error: ~a]~%"
                               backend condition)))))
             (when tool-context
               (cancel-project-request
                (llm-tool-context-project-request tool-context)))))
         (format nil "lem-yath/llm-~(~a~)" backend)
         (format nil "~%[failed to start ~(~a~) request]~%" backend))))))

(defmethod llm-backend-stream ((backend (eql :chatgpt-codex)) prompt)
  (llm-oauth-stream backend prompt))

(defmethod llm-backend-stream ((backend (eql :grok-oauth)) prompt)
  (llm-oauth-stream backend prompt))


;;;; ChatGPT Codex PKCE login

(defun llm-codex-login-claim ()
  (bt2:with-lock-held (*llm-codex-login-lock*)
    (unless *llm-codex-login-running-p*
      (setf *llm-codex-login-running-p* t))))

(defun llm-codex-login-release ()
  (bt2:with-lock-held (*llm-codex-login-lock*)
    (setf *llm-codex-login-running-p* nil)))

(defun llm-codex-login-publish (text &key url)
  (send-event
   (lambda ()
     (let ((buffer (make-buffer *llm-codex-login-buffer-name*)))
       (handler-case
           (change-buffer-mode buffer 'lem-markdown-mode:markdown-mode)
         (error () nil))
       (pop-to-buffer buffer)
       (llm-buffer-append-now buffer text)
       (when url
         (ignore-errors (copy-to-clipboard-with-killring url)))
       (when (and url *llm-codex-open-browser*
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

(defun llm-codex-pkce ()
  (let* ((verifier
           (llm-oauth-base64url-encode (llm-oauth-random-octets 32)))
         (challenge
           (llm-oauth-base64url-encode (llm-oauth-sha256 verifier))))
    (values verifier challenge)))

(defun llm-codex-authorization-url (challenge state)
  (format nil "~a?~a"
          *llm-codex-authorization-endpoint*
          (llm-oauth-form
           `(("response_type" . "code")
             ("client_id" . ,*llm-codex-client-id*)
             ("redirect_uri" . ,*llm-codex-redirect-uri*)
             ("scope" . "openid profile email offline_access")
             ("code_challenge" . ,challenge)
             ("code_challenge_method" . "S256")
             ("state" . ,state)
             ("id_token_add_organizations" . "true")
             ("codex_cli_simplified_flow" . "true")))))

(defun llm-codex-exchange-code (code verifier)
  (llm-http-json-request
   "POST" *llm-codex-token-endpoint*
   '(("Content-Type" . "application/x-www-form-urlencoded")
     ("Accept" . "application/json"))
   (llm-oauth-form
    `(("grant_type" . "authorization_code")
      ("code" . ,code)
      ("redirect_uri" . ,*llm-codex-redirect-uri*)
      ("client_id" . ,*llm-codex-client-id*)
      ("code_verifier" . ,verifier)))))

(defun llm-codex-persist-login (response)
  (let* ((auth (make-hash-table :test #'equal))
         (tokens (make-hash-table :test #'equal)))
    (setf (gethash "auth_mode" auth) "chatgpt"
          (gethash "OPENAI_API_KEY" auth) nil
          (gethash "tokens" auth) tokens)
    (llm-codex-apply-token-response auth response)
    (call-with-llm-oauth-file-lock
     (llm-codex-auth-pathname)
     (lambda ()
       (llm-oauth-write-json-file (llm-codex-auth-pathname) auth)))))

(defun llm-codex-read-request (stream)
  (let ((line (read-line stream nil)))
    (unless (and line (<= (length line) 16384))
      (error "Invalid OAuth callback request"))
    (let ((terminated-p nil))
      (loop :repeat 100
            :for header := (read-line stream nil)
            :do (when (or (null header)
                          (zerop (length
                                  (string-right-trim '(#\Return) header))))
                  (setf terminated-p t)
                  (return))
                (when (> (length header) 16384)
                  (error "Oversized OAuth callback header")))
      (unless terminated-p
        (error "OAuth callback has too many headers")))
    (let ((parts (uiop:split-string line :separator '(#\Space))))
      (unless (>= (length parts) 2)
        (error "Malformed OAuth callback request"))
      (values (first parts) (second parts)))))

(defun llm-codex-http-response (stream status body)
  (format stream
          "HTTP/1.1 ~a~c~cContent-Type: text/html; charset=utf-8~c~cConnection: close~c~cContent-Length: ~d~c~c~c~c~a"
          status #\Return #\Newline #\Return #\Newline
          #\Return #\Newline (length body)
          #\Return #\Newline #\Return #\Newline body)
  (finish-output stream))

(defun llm-codex-callback-code (path expected-state)
  (let ((question (position #\? path)))
    (unless (and question
                 (string= path "/auth/callback" :end1 question))
      (error "Unexpected OAuth callback path"))
    (let* ((params (quri:url-decode-params (subseq path (1+ question))))
           (code (cdr (assoc "code" params :test #'string=)))
           (state (cdr (assoc "state" params :test #'string=))))
      (unless (and state (string= state expected-state))
        (error "OAuth callback state mismatch"))
      (unless (llm-http-token-valid-p code)
        (error "OAuth callback omitted the authorization code"))
      code)))

(defun llm-codex-wait-for-callback (expected-state server)
  (let ((deadline (+ (get-internal-real-time)
                     (* *llm-codex-login-timeout*
                        internal-time-units-per-second))))
    (unwind-protect
         (loop
           (let ((remaining
                   (/ (max 0 (- deadline (get-internal-real-time)))
                      internal-time-units-per-second)))
             (when (zerop remaining)
               (error "ChatGPT Codex login timed out"))
             (let ((ready
                     (usocket:wait-for-input
                      server :timeout (min remaining 1) :ready-only t)))
               (when (and (null ready)
                          (>= (get-internal-real-time) deadline))
                 (error "ChatGPT Codex login timed out"))
               (when ready
                 (let ((client (usocket:socket-accept server)))
                   (unwind-protect
                        (let ((stream (usocket:socket-stream client)))
                          (handler-case
                              (multiple-value-bind (method path)
                                  (llm-codex-read-request stream)
                                (unless (string= method "GET")
                                  (error "OAuth callback requires GET"))
                                (let ((code
                                        (llm-codex-callback-code
                                         path expected-state)))
                                  (llm-codex-http-response
                                   stream "200 OK"
                                   "<html><body><h1>Signed in.</h1><p>You can close this tab.</p></body></html>")
                                  (return code)))
                            (error (condition)
                              (ignore-errors
                                (llm-codex-http-response
                                 stream "400 Bad Request"
                                 "<html><body><h1>Authentication failed.</h1></body></html>"))
                              (error condition))))
                     (ignore-errors (usocket:socket-close client))))))))
      (ignore-errors (usocket:socket-close server)))))

(defun llm-codex-login-flow ()
  (multiple-value-bind (verifier challenge) (llm-codex-pkce)
    (let* ((state
             (llm-oauth-base64url-encode (llm-oauth-random-octets 32)))
           (url (llm-codex-authorization-url challenge state))
           (server
             (usocket:socket-listen
              "127.0.0.1" *llm-codex-login-port*
              :reuse-address nil :element-type 'character)))
      (handler-case
          (progn
            (llm-codex-login-publish
             (format nil
                     "# ChatGPT Codex login~2%Open this URL:~2%~a~2%The URL was copied when clipboard access was available.~:[~;~2%Because Lem is running over SSH, connect with local forwarding for the registered callback: `ssh -L ~d:127.0.0.1:~d ex44`.~]~2%Waiting for authorization…~2%"
                     url
                     (or (uiop:getenv "SSH_CLIENT")
                         (uiop:getenv "SSH_CONNECTION")
                         (uiop:getenv "SSH_TTY"))
                     *llm-codex-login-port* *llm-codex-login-port*)
             :url url)
            (let* ((code (llm-codex-wait-for-callback state server))
                   (response (llm-codex-exchange-code code verifier)))
              (llm-codex-persist-login response)
              response))
        (error (condition)
          (ignore-errors (usocket:socket-close server))
          (error condition))))))

(defun llm-codex-login-synchronously ()
  (unless (llm-codex-login-claim)
    (error "ChatGPT Codex login is already running"))
  (unwind-protect
       (llm-codex-login-flow)
    (llm-codex-login-release)))

(define-command lem-yath-chatgpt-codex-login () ()
  "Authorize the native ChatGPT Codex backend with OAuth2 PKCE."
  (if (not (llm-codex-login-claim))
      (message "ChatGPT Codex login is already running")
      (progn
        (llm-codex-login-publish
         (format nil "Starting ChatGPT Codex authorization…~%"))
        (bt2:make-thread
         (lambda ()
           (unwind-protect
                (handler-case
                    (progn
                      (llm-codex-login-flow)
                      (llm-codex-login-publish
                       (format nil
                               "Authorization complete. ChatGPT Codex is ready.~%")))
                  (error (condition)
                    (llm-codex-login-publish
                     (format nil "Authorization failed: ~a~%" condition))))
             (llm-codex-login-release)))
         :name "lem-yath/chatgpt-codex-login"))))
