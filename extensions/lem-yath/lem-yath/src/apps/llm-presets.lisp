;;;; lem-yath apps/llm-presets -- gptel-style presets and web handoff.

(in-package :lem-yath)

(defparameter *llm-preset-file-size-limit* (* 1024 1024))
(defparameter *llm-preset-count-limit* 100)
(defparameter *llm-preset-name-limit* 80)
(defparameter *llm-preset-string-limit* (* 64 1024))

(defparameter *llm-builtin-presets*
  `(("quick-lookup"
     :backend :openrouter
     :model "openrouter/auto"
     :system "Short, direct answers. Skip extra context unless it changes correctness."
     :temperature 0.2
     :max-tokens 800
     :use-tools nil
     :mcp-servers nil)
    ("project-readonly"
     :backend :openrouter
     :model "openrouter/auto"
     :system "Use the provided project and Lem tools for discovery before answering. Prefer narrow searches and narrow file reads over guessing. Stay read-only."
     :temperature 0.2
     :max-tokens 4000
     :use-tools t
     :mcp-servers nil)
    ,@(when (llm-mcp-server-available-p "fetch")
        `(("web-readonly"
           :backend :openrouter
           :model "openrouter/auto"
           :system "When the task needs current external information, use the connected fetch MCP tool instead of relying on stale model knowledge. Use the provided project and Lem tools for local discovery. Stay read-only."
           :temperature 0.2
           :max-tokens 4000
           :use-tools t
           :mcp-servers ("fetch"))))
    ,@(when (llm-mcp-server-available-p "github")
        `(("github-readonly"
           :backend :openrouter
           :model "openrouter/auto"
           :system "When the task concerns repositories, pull requests, issues, or CI, use the connected read-only GitHub MCP tools. Use the provided project and Lem tools for local discovery. Stay read-only."
           :temperature 0.2
           :max-tokens 4000
           :use-tools t
           :mcp-servers ("github"))))
    ("grok-build"
     :backend :grok
     :model "grok-build"
     :system "You are a coding assistant. Answer directly; inspect the project only when needed."
     :temperature 0.2
     :max-tokens nil
     :use-tools nil
     :mcp-servers nil)
    ("codex-agentic"
     :backend :chatgpt-codex
     :model "gpt-5.4"
     :system "You are a coding agent. Use available tools first for project discovery, then answer with concrete, minimal steps or code edits."
     :temperature 0.2
     :max-tokens nil
     :use-tools t
     :mcp-servers nil)
    ("grok-build-oauth-agentic"
     :backend :grok-oauth
     :model "grok-build"
     :system "You are a coding assistant. Use available tools first for project discovery, then answer with concrete, minimal steps or code edits."
     :temperature 0.2
     :max-tokens nil
     :use-tools t
     :mcp-servers nil))
  "Built-in presets whose required transport exists in Lem-yath.")

(defvar *llm-current-preset* "quick-lookup")

(defvar *llm-handoff-max-chars* 13000)
(defvar *llm-claude-handoff-web-url* "https://claude.ai/new")
(defvar *llm-chatgpt-handoff-url* "https://chatgpt.com/")
(defvar *llm-chatgpt-handoff-model* nil)
(defvar *llm-handoff-browser-commands*
  '("/home/yanni/.nix-profile/bin/brave"
    "/run/current-system/sw/bin/brave"
    "brave"
    "brave-browser"
    "xdg-open"))
(defvar *llm-handoff-browser-arguments* '("--new-window"))

(defun llm-preset-file-override ()
  (uiop:getenv "LEM_YATH_LLM_PRESET_FILE"))

(defun llm-preset-pathname ()
  "Return the private user-preset JSON file."
  (alexandria:if-let ((override (llm-preset-file-override)))
    (uiop:parse-native-namestring override)
    (let ((configuration-home
            (alexandria:if-let ((xdg (uiop:getenv "XDG_CONFIG_HOME")))
              (uiop:ensure-directory-pathname
               (uiop:parse-native-namestring xdg))
              (merge-pathnames ".config/" (user-homedir-pathname)))))
      (merge-pathnames "lem-yath/llm-presets.json" configuration-home))))

(defun llm-preset-lock-pathname ()
  (uiop:parse-native-namestring
   (concatenate 'string (uiop:native-namestring (llm-preset-pathname))
                ".lock")))

(defun llm-preset-temporary-pathname (pathname)
  (uiop:parse-native-namestring
   (format nil "~a.tmp.~d.~16,'0x"
           (uiop:native-namestring pathname)
           #+sbcl (sb-posix:getpid)
           #-sbcl 0
           (random (ash 1 60)))))

(defun llm-preset-prepare-private-directory ()
  "Create or validate the preset directory without weakening an override."
  (let* ((pathname (llm-preset-pathname))
         (directory (uiop:pathname-directory-pathname pathname))
         (existed (uiop:directory-exists-p directory)))
    (ensure-directories-exist pathname)
    #+sbcl
    (if (and (llm-preset-file-override) existed)
        (let ((stat (sb-posix:stat (uiop:native-namestring directory))))
          (unless (and (= (sb-posix:stat-uid stat) (sb-posix:getuid))
                       (zerop (logand (sb-posix:stat-mode stat) #o077)))
            (error "LLM preset override directory must be private and user-owned")))
        (sb-posix:chmod (uiop:native-namestring directory) #o700))
    #-sbcl
    (error "Safe LLM preset persistence requires SBCL")
    directory))

(defun llm-preset-validate-existing-file (pathname)
  (when (uiop:file-exists-p pathname)
    #+sbcl
    (let ((stat (sb-posix:lstat (uiop:native-namestring pathname))))
      (unless (and (= (logand (sb-posix:stat-mode stat) sb-posix:s-ifmt)
                      sb-posix:s-ifreg)
                   (= (sb-posix:stat-uid stat) (sb-posix:getuid)))
        (error "LLM preset file must be a regular user-owned file")))
    #-sbcl
    (error "Safe LLM preset persistence requires SBCL")))

(defun call-with-llm-preset-lock (function)
  "Call FUNCTION while holding the private cross-process preset lock."
  (llm-preset-prepare-private-directory)
  (llm-preset-validate-existing-file (llm-preset-pathname))
  #+sbcl
  (let ((descriptor
          (sb-posix:open
           (uiop:native-namestring (llm-preset-lock-pathname))
           (logior sb-posix:o-creat sb-posix:o-rdwr sb-posix:o-nofollow)
           #o600)))
    (unwind-protect
         (progn
           (sb-posix:fchmod descriptor #o600)
           (let ((stat (sb-posix:fstat descriptor)))
             (unless (and (= (logand (sb-posix:stat-mode stat) sb-posix:s-ifmt)
                             sb-posix:s-ifreg)
                          (= (sb-posix:stat-uid stat) (sb-posix:getuid)))
               (error "LLM preset lock must be a regular user-owned file")))
           (sb-posix:lockf descriptor sb-posix:f-lock 0)
           (funcall function))
      (ignore-errors (sb-posix:lockf descriptor sb-posix:f-ulock 0))
      (ignore-errors (sb-posix:close descriptor))))
  #-sbcl
  (error "Safe LLM preset persistence requires SBCL"))

(defun llm-preset-read-text (pathname)
  (with-open-file (stream pathname :element-type '(unsigned-byte 8))
    (let ((length (file-length stream)))
      (when (> length *llm-preset-file-size-limit*)
        (error "LLM preset file exceeds the size limit"))
      (let ((octets (make-array length :element-type '(unsigned-byte 8))))
        (unless (= length (read-sequence octets stream))
          (error "Could not read the complete LLM preset file"))
        #+sbcl (sb-ext:octets-to-string octets :external-format :utf-8)
        #-sbcl (error "UTF-8 preset decoding requires SBCL")))))

(defun llm-preset-backend (value)
  (and (stringp value)
       (cdr (assoc value
                   '(("openrouter" . :openrouter)
                     ("perplexity" . :perplexity)
                     ("copilot" . :copilot)
                     ("chatgpt-codex" . :chatgpt-codex)
                     ("grok-oauth" . :grok-oauth)
                     ("claude-code" . :claude-code)
                     ("codex" . :codex)
                     ("grok" . :grok))
                   :test #'string=))))

(defun llm-preset-backend-name (backend)
  (string-downcase (symbol-name backend)))

(defun llm-preset-name-valid-p (name)
  (and (stringp name)
       (plusp (length name))
       (<= (length name) *llm-preset-name-limit*)
       (every (lambda (character)
                (and (graphic-char-p character)
                     (not (member character '(#\Newline #\Return #\Tab)))))
              name)))

(defun llm-preset-valid-p (name preset)
  (and (llm-preset-name-valid-p name)
       (member (getf preset :backend)
               '(:openrouter :perplexity :copilot :chatgpt-codex :grok-oauth
                 :claude-code :codex :grok))
       (stringp (getf preset :model))
       (<= (length (getf preset :model)) *llm-preset-string-limit*)
       (stringp (getf preset :system))
       (<= (length (getf preset :system)) *llm-preset-string-limit*)
       (let ((temperature (getf preset :temperature)))
         (or (null temperature)
             (and (realp temperature) (<= 0 temperature 2))))
       (let ((maximum (getf preset :max-tokens)))
         (or (null maximum)
             (and (integerp maximum) (<= 1 maximum 1000000))))
       (member (getf preset :use-tools) '(nil t))
       (or (null (getf preset :use-tools))
           (member (getf preset :backend)
                   '(:openrouter :chatgpt-codex :grok-oauth)))
       (let ((servers (getf preset :mcp-servers)))
         (and (listp servers)
              (= (length servers)
                 (length (remove-duplicates servers :test #'string=)))
              (every (lambda (server)
                       (member server '("fetch" "github") :test #'string=))
                     servers)
              (or (null servers)
                  (and (eq (getf preset :backend) :openrouter)
                       (getf preset :use-tools)))))))

(defun llm-preset-mcp-servers-from-json (value)
  (let ((values (cond ((null value) nil)
                      ((vectorp value) (coerce value 'list))
                      ((listp value) value)
                      (t :invalid))))
    values))

(defun llm-preset-from-json (object)
  (when (hash-table-p object)
    (let* ((name (gethash "name" object))
           (preset
             (list :backend (llm-preset-backend (gethash "backend" object))
                   :model (gethash "model" object)
                   :system (gethash "system" object)
                   :temperature (gethash "temperature" object)
                   :max-tokens (gethash "max_tokens" object)
                   :use-tools (gethash "use_tools" object)
                   :mcp-servers
                   (llm-preset-mcp-servers-from-json
                    (gethash "mcp_servers" object)))))
      (and (llm-preset-valid-p name preset) (cons name preset)))))

(defun llm-read-user-presets ()
  "Read and validate user presets; malformed state yields no presets."
  (let ((pathname (llm-preset-pathname)))
    (if (uiop:file-exists-p pathname)
        (handler-case
            (progn
              (llm-preset-validate-existing-file pathname)
              (let* ((root (yason:parse (llm-preset-read-text pathname)
                                        :json-arrays-as-vectors t))
                     (version (and (hash-table-p root)
                                   (gethash "version" root)))
                     (objects (and (= version 1)
                                   (gethash "presets" root)))
                     (entries
                       (loop :for object :across
                               (if (vectorp objects) objects #())
                             :for entry := (llm-preset-from-json object)
                             :when entry :collect entry)))
                (subseq entries 0 (min (length entries)
                                       *llm-preset-count-limit*))))
          (error () nil))
        nil)))

(defun llm-preset-json-object (name preset)
  (alexandria:alist-hash-table
   `(("name" . ,name)
     ("backend" . ,(llm-preset-backend-name (getf preset :backend)))
     ("model" . ,(getf preset :model))
     ("system" . ,(getf preset :system))
     ("temperature" . ,(getf preset :temperature))
     ("max_tokens" . ,(getf preset :max-tokens))
     ("use_tools" . ,(getf preset :use-tools))
     ("mcp_servers" . ,(coerce (getf preset :mcp-servers) 'vector)))
   :test #'equal))

(defun llm-preset-json-text (presets)
  (with-output-to-string (stream)
    (yason:encode
     (alexandria:alist-hash-table
      `(("version" . 1)
        ("presets" . ,(coerce
                        (mapcar (lambda (entry)
                                  (llm-preset-json-object
                                   (car entry) (cdr entry)))
                                presets)
                        'vector)))
      :test #'equal)
     stream)))

(defun llm-write-user-presets (presets)
  "Atomically write validated PRESETS with private permissions."
  (let* ((pathname (llm-preset-pathname))
         (temporary (llm-preset-temporary-pathname pathname))
         (text (llm-preset-json-text presets))
         (octets #+sbcl (sb-ext:string-to-octets text :external-format :utf-8)
                 #-sbcl (error "UTF-8 preset encoding requires SBCL"))
         (descriptor nil)
         (stream nil))
    (when (> (length octets) *llm-preset-file-size-limit*)
      (error "Refusing an oversized LLM preset file"))
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
           #-sbcl
           (error "Safe LLM preset persistence requires SBCL")
           (uiop:rename-file-overwriting-target temporary pathname)
           #+sbcl (sb-posix:chmod (uiop:native-namestring pathname) #o600))
      (when stream
        (ignore-errors (close stream :abort t))
        (setf descriptor nil))
      (when descriptor (ignore-errors (sb-posix:close descriptor)))
      (when (uiop:file-exists-p temporary)
        (ignore-errors (delete-file temporary))))))

(defun llm-all-presets ()
  "Return user and built-in presets, with user definitions taking precedence."
  (remove-duplicates (append (llm-read-user-presets) *llm-builtin-presets*)
                     :key #'car :test #'string= :from-end t))

(defun llm-current-settings ()
  (list :backend *llm-backend*
        :model *llm-model*
        :system *llm-system-message*
        :temperature *llm-temperature*
        :max-tokens *llm-max-tokens*
        :use-tools *llm-use-tools*
        :mcp-servers (copy-list *llm-mcp-server-names*)))

(defun llm-apply-preset (name preset)
  "Apply validated PRESET named NAME to the live LLM settings."
  (unless (llm-preset-valid-p name preset)
    (error "Invalid LLM preset ~s" name))
  (let* ((backend (getf preset :backend))
         (model (llm-compatible-model-for-backend
                 backend (getf preset :model))))
    (setf *llm-backend* backend
          *llm-model* model
          *llm-system-message* (getf preset :system)
          *llm-temperature* (getf preset :temperature)
          *llm-max-tokens* (getf preset :max-tokens)
          *llm-use-tools* (getf preset :use-tools)
          *llm-mcp-server-names* (copy-list (getf preset :mcp-servers))
          *llm-current-preset* name))
  preset)

(defun llm-load-preset (name)
  "Load the named preset NAME, returning it or NIL."
  (alexandria:when-let ((entry (assoc name (llm-all-presets) :test #'string=)))
    (llm-apply-preset (car entry) (cdr entry))))

(defun llm-save-preset (name)
  "Persist the current settings under NAME, merging under a cross-process lock."
  (unless (llm-preset-name-valid-p name)
    (error "Invalid LLM preset name"))
  (let ((preset (llm-current-settings)))
    (unless (llm-preset-valid-p name preset)
      (error "Current LLM settings cannot be saved as a preset"))
    (call-with-llm-preset-lock
     (lambda ()
       (let ((presets (remove name (llm-read-user-presets)
                              :key #'car :test #'string=)))
         (push (cons name preset) presets)
         (setf presets (subseq presets 0 (min (length presets)
                                              *llm-preset-count-limit*)))
         (llm-write-user-presets presets))))
    (setf *llm-current-preset* name)
    preset))

(define-command lem-yath-llm-load-preset () ()
  "Load a built-in or saved LLM preset."
  (let* ((presets (llm-all-presets))
         (names (mapcar #'car presets))
         (choice (prompt-for-string
                  "LLM preset: "
                  :completion-function (lambda (input)
                                         (prescient-filter input names))
                  :initial-value *llm-current-preset*
                  :history-symbol 'lem-yath-llm-preset)))
    (if (llm-load-preset choice)
        (message "Loaded LLM preset: ~a" choice)
        (message "Unknown LLM preset: ~a" choice))))

(define-command lem-yath-llm-save-preset () ()
  "Save the current LLM settings as a named preset."
  (let ((name (prompt-for-string "Save LLM preset: "
                                 :initial-value *llm-current-preset*
                                 :history-symbol 'lem-yath-llm-preset)))
    (handler-case
        (progn
          (llm-save-preset name)
          (message "Saved LLM preset: ~a" name))
      (error () (message "Could not save LLM preset")))))

(defun llm-handoff-region-text (buffer)
  (if (buffer-mark-p buffer)
      (let ((global-mode (current-global-mode)))
        (points-to-string
         (region-beginning-using-global-mode global-mode buffer)
         (region-end-using-global-mode global-mode buffer)))
      (points-to-string (buffer-start-point buffer) (buffer-end-point buffer))))

(defun llm-handoff-abbreviate-path (pathname)
  (let ((path (uiop:native-namestring pathname))
        (home (uiop:native-namestring (user-homedir-pathname))))
    (if (and (<= (length home) (length path))
             (string= home path :end2 (length home)))
        (concatenate 'string "~/" (subseq path (length home)))
        path)))

(defun llm-handoff-context-header (target buffer)
  (with-output-to-string (stream)
    (format stream "I was working in gptel. Continue from this context in ~a.~%~%"
            target)
    (format stream "Buffer: ~a~%" (buffer-name buffer))
    (format stream "Mode: ~a~%" (buffer-major-mode buffer))
    (when (buffer-filename buffer)
      (format stream "File: ~a~%"
              (llm-handoff-abbreviate-path (buffer-filename buffer))))
    (alexandria:when-let
        ((root (lem-yath-project-root-for-directory (buffer-directory buffer))))
      (format stream "Project: ~a~%" (llm-handoff-abbreviate-path root)))))

(defun llm-handoff-truncate (text &optional (limit *llm-handoff-max-chars*))
  "Cap TEXT to LIMIT, retaining the most recent context like the Emacs setup."
  (if (or (null limit) (zerop limit) (<= (length text) limit))
      text
      (let* ((notice (format nil "[Truncated by Lem from ~d to ~d characters.]~%~%"
                             (length text) limit))
             (notice (if (> (length notice) limit)
                         (subseq notice 0 limit)
                         notice))
             (body-limit (- limit (length notice))))
        (concatenate 'string notice (subseq text (- (length text) body-limit))))))

(defun llm-handoff-prompt (target &optional (buffer (current-buffer)))
  (llm-handoff-truncate
   (format nil "~a~%Context:~%~%~a"
           (llm-handoff-context-header target buffer)
           (string-trim '(#\Space #\Tab #\Newline #\Return)
                        (llm-handoff-region-text buffer)))))

(defun llm-url-query (parameters)
  (format nil "~{~a~^&~}"
          (mapcar (lambda (entry)
                    (format nil "~a=~a"
                            (quri:url-encode (car entry))
                            (quri:url-encode (cdr entry))))
                  parameters)))

(defun llm-url-add-query (base parameters)
  (format nil "~a~a~a" base (if (find #\? base) "&" "?")
          (llm-url-query parameters)))

(defun llm-handoff-executable (command)
  (if (uiop:absolute-pathname-p (uiop:parse-native-namestring command))
      (let ((pathname (uiop:probe-file* command)))
        #+sbcl
        (and pathname
             (zerop (sb-posix:access (uiop:native-namestring pathname)
                                    sb-posix:x-ok))
             pathname)
        #-sbcl pathname)
      (executable-find command)))

(defun llm-handoff-browser ()
  (loop :for command :in *llm-handoff-browser-commands*
        :for executable := (ignore-errors (llm-handoff-executable command))
        :when executable :return executable))

(defun llm-handoff-open-url (url)
  "Open URL as argv in the configured browser; return its executable."
  (alexandria:if-let ((browser (llm-handoff-browser)))
    (handler-case
        (progn
          (uiop:launch-program
           (append (list (uiop:native-namestring browser))
                   (unless (string= (file-namestring browser) "xdg-open")
                     *llm-handoff-browser-arguments*)
                   (list url))
           :input nil :output nil :error-output nil)
          browser)
      (error () (message "Could not launch the LLM handoff browser") nil))
    (progn (message "No LLM handoff browser is available") nil)))

(define-command lem-yath-llm-handoff-claude () ()
  "Open Claude web with the active region or current buffer as context."
  (let* ((prompt (llm-handoff-prompt "Claude"))
         (url (llm-url-add-query *llm-claude-handoff-web-url*
                                 `(("q" . ,prompt)))))
    (when (llm-handoff-open-url url)
      (message "Opened Claude handoff with ~d characters" (length prompt)))))

(defun llm-chatgpt-handoff (mode)
  (let* ((prompt (llm-handoff-prompt "ChatGPT"))
         (prompt (if (eq mode :research)
                     (format nil "/Deepresearch~2%~a" prompt)
                     prompt))
         (parameters `(("q" . ,prompt)))
         (parameters
           (if (member mode '(:temporary :search :research :model))
               (append parameters '(("temporary-chat" . "true")))
               parameters))
         (parameters (if (eq mode :search)
                         (append parameters '(("hints" . "search")))
                         parameters))
         (parameters
           (if (and (eq mode :model)
                    (stringp *llm-chatgpt-handoff-model*)
                    (plusp (length *llm-chatgpt-handoff-model*)))
               (append parameters `(("model" . ,*llm-chatgpt-handoff-model*)))
               parameters))
         (url (llm-url-add-query *llm-chatgpt-handoff-url* parameters)))
    (copy-to-clipboard-with-killring prompt)
    (when (llm-handoff-open-url url)
      (message "Opened ChatGPT ~(~a~) handoff with ~d characters"
               mode (length prompt)))))

(define-command lem-yath-llm-handoff-chatgpt () ()
  (llm-chatgpt-handoff :normal))

(define-command lem-yath-llm-handoff-chatgpt-temporary () ()
  (llm-chatgpt-handoff :temporary))

(define-command lem-yath-llm-handoff-chatgpt-search () ()
  (llm-chatgpt-handoff :search))

(define-command lem-yath-llm-handoff-chatgpt-research () ()
  (llm-chatgpt-handoff :research))

(define-command lem-yath-llm-handoff-chatgpt-model () ()
  (unless (and (stringp *llm-chatgpt-handoff-model*)
               (plusp (length *llm-chatgpt-handoff-model*)))
    (setf *llm-chatgpt-handoff-model*
          (prompt-for-string "ChatGPT model hint: "
                             :history-symbol 'lem-yath-llm-model)))
  (llm-chatgpt-handoff :model))

(defun llm-menu-number-string (value)
  (if value (princ-to-string value) ""))

(defun llm-menu-temperature-value (text)
  "Parse a decimal temperature in TEXT, returning NIL for the API default."
  (let ((text (string-trim '(#\Space #\Tab #\Newline #\Return) text)))
    (cond
      ((zerop (length text)) nil)
      ((cl-ppcre:scan "^[0-9]+(?:\\.[0-9]+)?$" text)
       (let ((*read-eval* nil))
         (ignore-errors (read-from-string text))))
      (t :invalid))))

(defun llm-menu-temperature-valid-p (text)
  (let ((value (llm-menu-temperature-value text)))
    (or (null value)
        (and (numberp value) (<= 0 value 2)))))

(defun llm-menu-token-value (text)
  "Parse a response-token cap in TEXT, returning NIL for the API default."
  (let ((text (string-trim '(#\Space #\Tab #\Newline #\Return) text)))
    (cond
      ((zerop (length text)) nil)
      ((every #'digit-char-p text)
       (ignore-errors (parse-integer text :junk-allowed nil)))
      (t :invalid))))

(defun llm-menu-token-valid-p (text)
  (let ((value (llm-menu-token-value text)))
    (or (null value)
        (and (integerp value) (<= 1 value 1000000)))))

(defun llm-menu-tools-supported-p (&optional (backend *llm-backend*))
  (member backend '(:openrouter :chatgpt-codex :grok-oauth)))

(define-command lem-yath-llm-set-system-message () ()
  "Set the system instruction used by subsequent LLM requests."
  (setf *llm-system-message*
        (prompt-for-string "System message: "
                           :initial-value *llm-system-message*
                           :test-function
                           (lambda (text)
                             (<= (length text) *llm-preset-string-limit*))
                           :history-symbol 'lem-yath-llm-system-message))
  (llm-mark-settings-custom)
  (message "LLM system message updated"))

(define-command lem-yath-llm-set-temperature () ()
  "Set request temperature from 0 through 2, or blank for the API default."
  (let* ((text (prompt-for-string
                "Temperature (0-2, blank for API default): "
                :initial-value (llm-menu-number-string *llm-temperature*)
                :test-function #'llm-menu-temperature-valid-p
                :history-symbol 'lem-yath-llm-temperature))
         (value (llm-menu-temperature-value text)))
    (setf *llm-temperature* value)
    (llm-mark-settings-custom)
    (message "LLM temperature: ~a" (or value "API default"))))

(define-command lem-yath-llm-set-max-tokens () ()
  "Set the response-token cap, or blank to use the provider default."
  (let* ((text (prompt-for-string
                "Response tokens (blank for API default): "
                :initial-value (llm-menu-number-string *llm-max-tokens*)
                :test-function #'llm-menu-token-valid-p
                :history-symbol 'lem-yath-llm-max-tokens))
         (value (llm-menu-token-value text)))
    (setf *llm-max-tokens* value)
    (llm-mark-settings-custom)
    (message "LLM response tokens: ~a" (or value "API default"))))

(define-command lem-yath-llm-toggle-tools () ()
  "Toggle bounded LLM tools when the active backend supports them."
  (if (llm-menu-tools-supported-p)
      (progn
        (setf *llm-use-tools* (not *llm-use-tools*))
        (llm-mark-settings-custom)
        (unless *llm-use-tools*
          (setf *llm-mcp-server-names* nil))
        (message "LLM tools ~:[disabled~;enabled~]" *llm-use-tools*))
      (progn
        (setf *llm-use-tools* nil
              *llm-mcp-server-names* nil)
        (message "~:(~a~) does not support Lem's LLM tools" *llm-backend*))))

(defun llm-menu-value-label (value)
  (completion-truncate-display-width
   (if (and (stringp value) (zerop (length value))) "(empty)" value)
   56))

(defun llm-menu-display-keymap (description entries)
  (let ((keymap (make-keymap :description description)))
    (setf (lem/transient::keymap-display-style keymap) :column)
    ;; Lem's keymap insertion order is stack-like; reverse the source order so
    ;; the popup reads top-to-bottom like the corresponding Emacs transient.
    (dolist (entry (reverse entries))
      (destructuring-bind (key label) entry
        (define-key keymap key 'nop-command)
        (setf (lem-core::prefix-description
               (lem-core::keymap-find keymap
                                      (lem-core::parse-keyspec key)))
              label)))
    keymap))

(defun llm-context-menu-keymap ()
  (let ((keymap
          (llm-menu-display-keymap
           (format nil "Request context: ~d source~:p" (llm-context-count))
           '(("r" "add active region")
             ("b" "add buffer")
             ("f" "add file or directory")
             ("d" "remove all context")
             ("e" "add configured Emacs Lisp tree")
             ("q" "cancel")))))
    (setf (lem/transient::keymap-show-p keymap) t)
    keymap))

(defun llm-context-menu-command (key)
  (cdr (assoc key
              '(("r" . lem-yath-llm-context-add-region)
                ("b" . lem-yath-llm-context-add-buffer)
                ("f" . lem-yath-llm-context-add-file)
                ("d" . lem-yath-llm-context-clear)
                ("e" . vile-config/add-elisp-to-gptel-context))
              :test #'string=)))

(define-command lem-yath-llm-context-menu () ()
  "Dispatch gptel-compatible -r, -b, -f, and -d context actions."
  (unwind-protect
       (progn
         (let ((lem/transient:*transient-popup-delay* 0))
           (keymap-activate (llm-context-menu-keymap)))
         (redraw-display)
         (let* ((key (read-key))
                (name (lem-core::keyseq-to-string (list key))))
           (lem/transient::hide-transient)
           (unless (or (string= name "q") (string= name "Escape"))
             (alexandria:if-let ((command (llm-context-menu-command name)))
               (call-command command nil)
               (message "No LLM context action is bound to -~a" name)))))
    (lem/transient::hide-transient)))

(defun llm-full-menu-keymap ()
  (let ((keymap
          (make-keymap
           :description
           (format nil "LLM: ~a / ~(~a~) / ~a"
                   *llm-current-preset* *llm-backend* *llm-model*))))
    (setf (lem/transient::keymap-show-p keymap) t
          (lem/transient::keymap-display-style keymap) :row)
    (dolist
        (child
          (remove
           nil
           (list
           (llm-menu-display-keymap
            "Instructions and presets"
            (list
             (list "s" (format nil "system message: ~a"
                                (llm-menu-value-label *llm-system-message*)))
             (list "d" "additional directive and send")
             (list "@" (format nil "load preset: ~a" *llm-current-preset*))
             (list "S" "save current settings as preset")))
           (llm-menu-display-keymap
            "Request parameters"
            (list
             (list "B" (format nil "backend: ~(~a~)" *llm-backend*))
             (list "m" (format nil "model: ~a" *llm-model*))
             (list "c" (format nil "response tokens: ~a"
                                (or *llm-max-tokens* "API default")))
             (list "T" (format nil "temperature: ~a"
                                (or *llm-temperature* "API default")))
             (list "t" (format nil "use tools: ~a"
                                (if (llm-menu-tools-supported-p)
                                    (if *llm-use-tools* "on" "off")
                                    "unsupported")))))
           (llm-menu-display-keymap
            (format nil "Response to: ~a"
                    (llm-response-destination-label))
            '(("." "current/default")
              ("e" "echo area")
              ("b" "other buffer")
              ("g" "LLM session")
              ("k" "kill-ring")))
           (llm-menu-display-keymap
            "Actions and diagnostics"
            (remove
             nil
             (list
              (list "j" "send")
              (list "Return" "send")
              (list "n" "new conversation")
              (list "a" "abort request")
              (list "-" (format nil "context sources: ~d"
                                 (llm-context-count)))
              (list "I" "inspect request context")
              (list "J" "inspect next request (JSON)")
              (when (or (buffer-mark-p (current-buffer))
                        (ignore-errors (llm-rewrite-state-at-point)))
                (list "r" (if (buffer-mark-p (current-buffer))
                                "rewrite selected region"
                                "pending rewrite actions")))
              (list "x" (format nil "request tracing: ~:[off~;on~]"
                                 (and (boundp '*llm-request-trace-enabled*)
                                      (symbol-value
                                       '*llm-request-trace-enabled*))))
              (list "L" "inspect request log")
              (list "q" "cancel"))))
           (when (llm-response-at-point-p)
             (llm-menu-display-keymap
              "Tweak response"
              (remove
               nil
               (list
                (list "Space" "mark response")
                (list "M-Return" "regenerate")
                (when (llm-response-history-at-point-p)
                  (list "P" "previous variant"))
                (when (llm-response-history-at-point-p)
                  (list "N" "next variant"))
                (when (llm-response-history-at-point-p)
                  (list "E" "compare previous (unified)")))))))))
      (lem-core::keymap-add-child keymap child t))
    keymap))

(defun llm-full-menu-action (key)
  "Return command and whether the full menu should reopen for KEY."
  (alexandria:when-let
      ((entry
         (assoc key
                '(("s" lem-yath-llm-set-system-message t)
                  ("d" lem-yath-llm-ask nil)
                  ("@" lem-yath-llm-load-preset t)
                  ("S" lem-yath-llm-save-preset t)
                  ("B" lem-yath-llm-set-backend t)
                  ("m" lem-yath-llm-set-model t)
                  ("c" lem-yath-llm-set-max-tokens t)
                  ("T" lem-yath-llm-set-temperature t)
                  ("t" lem-yath-llm-toggle-tools t)
                  ("." lem-yath-llm-response-current t)
                  ("e" lem-yath-llm-response-echo t)
                  ("b" lem-yath-llm-response-buffer t)
                  ("g" lem-yath-llm-response-conversation t)
                  ("k" lem-yath-llm-response-kill-ring t)
                  ("j" lem-yath-llm-send nil)
                  ("Return" lem-yath-llm-send nil)
                  ("n" lem-yath-llm-new-session nil)
                  ("a" lem-yath-llm-abort nil)
                  ("-" lem-yath-llm-context-menu t)
                  ("I" lem-yath-llm-context-inspect nil)
                  ("J" lem-yath-llm-inspect-request-json nil)
                  ("r" lem-yath-llm-rewrite nil)
                  ("Space" lem-yath-llm-response-mark nil)
                  ("M-Return" lem-yath-llm-response-regenerate nil)
                  ("P" lem-yath-llm-response-previous nil)
                  ("N" lem-yath-llm-response-next nil)
                  ("E" lem-yath-llm-response-diff nil)
                  ("x" lem-yath-llm-request-trace-toggle t)
                  ("L" lem-yath-llm-request-trace-open nil))
                :test #'string=)))
    (values (second entry) (third entry))))

(define-command lem-yath-llm-full-menu () ()
  "Show the supported request settings and lifecycle actions from gptel-menu."
  (let ((*llm-response-destination* nil)
        (*llm-response-destination-buffer-name* nil))
    (unwind-protect
         (loop
           (let ((lem/transient:*transient-popup-delay* 0))
             (keymap-activate (llm-full-menu-keymap)))
           (redraw-display)
           (let* ((key (read-key))
                  (name (lem-core::keyseq-to-string (list key))))
             (lem/transient::hide-transient)
             (cond
               ((or (string= name "q") (string= name "Escape")) (return))
               (t
                (multiple-value-bind (command reopen-p)
                    (llm-full-menu-action name)
                  (if command
                      (progn
                        (call-command command nil)
                        (unless reopen-p (return)))
                      (message "No full LLM action is bound to ~a" name)))))))
      (lem/transient::hide-transient))))

(defun llm-menu-keymap ()
  (let ((keymap (make-keymap :description
                             (format nil "LLM preset: ~a"
                                     *llm-current-preset*))))
    (setf (lem/transient::keymap-show-p keymap) t
          (lem/transient::keymap-display-style keymap) :row)
    (dolist
        (child
          (list
           (llm-menu-display-keymap
            "Presets"
            '(("l" "load preset")
              ("s" "save preset")))
           (llm-menu-display-keymap
            "Handoff"
            '(("c" "open in Claude")
              ("g" "open in ChatGPT")
              ("r" "open ChatGPT research")
              ("w" "open ChatGPT search")
              ("G" "open ChatGPT model")))
           (llm-menu-display-keymap
            "Advanced"
            '(("m" "open full LLM menu")
              ("q" "cancel")))))
      (lem-core::keymap-add-child keymap child t))
    keymap))

(defun llm-menu-command (key)
  (cdr (assoc key
              '(("l" . lem-yath-llm-load-preset)
                ("s" . lem-yath-llm-save-preset)
                ("c" . lem-yath-llm-handoff-claude)
                ("g" . lem-yath-llm-handoff-chatgpt)
                ("r" . lem-yath-llm-handoff-chatgpt-research)
                ("w" . lem-yath-llm-handoff-chatgpt-search)
                ("G" . lem-yath-llm-handoff-chatgpt-model)
                ("m" . lem-yath-llm-full-menu))
              :test #'string=)))

(define-command lem-yath-llm-menu () ()
  "Show the gptel-style preset and handoff menu and dispatch one action."
  (unwind-protect
       (loop
         (let ((lem/transient:*transient-popup-delay* 0))
           (keymap-activate (llm-menu-keymap)))
         (redraw-display)
         (let* ((key (read-key))
                (name (lem-core::keyseq-to-string (list key))))
           (lem/transient::hide-transient)
           (cond
             ((or (string= name "q") (string= name "Escape")) (return))
             ((llm-menu-command name)
              (call-command (llm-menu-command name) nil)
              (return))
             (t (message "No LLM action is bound to ~a" name)))))
    (lem/transient::hide-transient)))
