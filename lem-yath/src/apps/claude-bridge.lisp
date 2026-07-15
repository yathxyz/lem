;;;; lem-yath apps/claude-bridge -- authenticated Claude/Lem MCP bridge.

(in-package :lem-yath)

(defparameter *claude-bridge-default-port* 7890)
(defparameter *claude-bridge-review-input-limit* (* 16 1024 1024))
(defparameter *claude-bridge-review-limit* 64)

(defvar *claude-bridge-server* nil)
(defvar *claude-bridge-token* nil)
(defvar *claude-bridge-config-pathname* nil)
(defvar *claude-bridge-review-counter* 0)
(defvar *claude-bridge-reviews* (make-hash-table :test 'equal))
(defvar *claude-bridge-review-buffers* (make-hash-table :test 'eq))

(defclass claude-bridge-review ()
  ((id :initarg :id :reader claude-bridge-review-id)
   (buffer :initarg :buffer :accessor claude-bridge-review-buffer)
   (tick :initarg :tick :reader claude-bridge-review-tick)
   (original :initarg :original :accessor claude-bridge-review-original)
   (proposed :initarg :proposed :accessor claude-bridge-review-proposed)
   (status :initform :pending :accessor claude-bridge-review-status)
   (display-buffer :initform nil :accessor claude-bridge-review-display-buffer)))

(defun claude-bridge-live-buffer-p (buffer)
  (and buffer (not (deleted-buffer-p buffer))))

(defun claude-bridge-random-token ()
  "Return a 256-bit bearer token encoded as lowercase hexadecimal."
  #+sbcl
  (let ((octets (make-array 32 :element-type '(unsigned-byte 8))))
    (with-open-file (stream #P"/dev/urandom"
                            :direction :input
                            :element-type '(unsigned-byte 8))
      (unless (= (read-sequence octets stream) (length octets))
        (error "Could not read a complete Claude bridge token")))
    (with-output-to-string (output)
      (loop :for octet :across octets
            :do (format output "~2,'0x" octet))))
  #-sbcl
  (error "The Claude bridge requires the supported SBCL runtime"))

(defun claude-bridge-explicit-port ()
  (alexandria:if-let ((text (uiop:getenv "LEM_YATH_CLAUDE_MCP_PORT")))
    (let ((port (ignore-errors (parse-integer text))))
      (unless (and port (<= 1 port 65535))
        (error "LEM_YATH_CLAUDE_MCP_PORT must be between 1 and 65535"))
      port)
    nil))

(defun claude-bridge-token-character-p (character)
  (or (char<= #\0 character #\9)
      (char<= #\A character #\Z)
      (char<= #\a character #\z)
      (member character '(#\- #\_ #\. #\~))))

(defun claude-bridge-token ()
  (let ((token (or (uiop:getenv "LEM_YATH_CLAUDE_MCP_TOKEN")
                   (claude-bridge-random-token))))
    (unless (and (>= (length token) 32)
                 (every #'claude-bridge-token-character-p token))
      (error
       "LEM_YATH_CLAUDE_MCP_TOKEN must be 32+ URL-safe token characters"))
    token))

(defun claude-bridge-config-pathname ()
  (let* ((cache (or (uiop:getenv "XDG_CACHE_HOME")
                    (merge-pathnames #P".cache/" (user-homedir-pathname))))
         (directory
           (merge-pathnames #P"lem-yath/"
                            (uiop:ensure-directory-pathname cache))))
    (merge-pathnames
     (format nil "claude-mcp-~D.json"
             #+sbcl (sb-posix:getpid)
             #-sbcl 0)
     directory)))

(defun claude-bridge-config-json (port token)
  (format nil
          (concatenate
           'string
           "{\"mcpServers\":{\"lem\":{\"type\":\"http\","
           "\"url\":\"http://127.0.0.1:~D/mcp\","
           "\"headers\":{\"Authorization\":\"Bearer ~A\"}}}}~%")
          port token))

(defun claude-bridge-server-live-p ()
  (and *claude-bridge-server*
       (eq *claude-bridge-server*
           (lem-mcp-server:current-mcp-server))))

(defun claude-bridge-start-server-at-port (port)
  (let ((server
          (make-instance 'lem-mcp-server::mcp-server
                         :hostname "127.0.0.1"
                         :port port)))
    (handler-case
        (values (lem-mcp-server:start-mcp-server server) nil)
      (error (condition)
        (ignore-errors (lem-mcp-server:stop-mcp-server server))
        (values nil condition)))))

(defun claude-bridge-start-server ()
  (alexandria:if-let ((explicit (claude-bridge-explicit-port)))
    (multiple-value-bind (server condition)
        (claude-bridge-start-server-at-port explicit)
      (or server
          (error "Could not start Claude bridge on configured port ~D: ~A"
                 explicit condition)))
    (let ((last-condition nil))
      (loop :for port :in
              (cons *claude-bridge-default-port*
                    (loop :repeat 32
                          :collect (+ 10000 (random 55536))))
            :do (multiple-value-bind (server condition)
                    (claude-bridge-start-server-at-port port)
                  (when server (return server))
                  (setf last-condition condition))
            :finally
               (error "Could not find a free Claude bridge port: ~A"
                      last-condition)))))

(defun claude-bridge-start ()
  "Start the authenticated loopback MCP server and return its config path."
  (when (claude-bridge-server-live-p)
    (return-from claude-bridge-start *claude-bridge-config-pathname*))
  (when (lem-mcp-server:current-mcp-server)
    (editor-error
     "Another Lem MCP server is running; stop it before starting Claude bridge"))
  (let* ((token (claude-bridge-token))
         (pathname (claude-bridge-config-pathname))
         (server nil)
         (complete-p nil))
    (unwind-protect
         (progn
           (setf lem-mcp-server:*mcp-server-auth-token* token
                 lem-mcp-server:*mcp-disabled-tools*
                 '("eval_expression" "command_execute")
                 lem-mcp-server:*mcp-allow-file-resources* nil)
           (setf server (claude-bridge-start-server))
           (server-ensure-private-directory pathname)
           (server-write-private-file
            pathname
            (claude-bridge-config-json
             (lem-mcp-server:mcp-server-port server) token))
           (setf *claude-bridge-server* server
                 *claude-bridge-token* token
                 *claude-bridge-config-pathname* pathname
                 complete-p t)
           pathname)
      (unless complete-p
        (ignore-errors (lem-mcp-server:stop-mcp-server server))
        (ignore-errors (delete-file pathname))
        (setf lem-mcp-server:*mcp-server-auth-token* nil)))))

(defun claude-bridge-close-review-buffer (review)
  (let ((buffer (claude-bridge-review-display-buffer review)))
    (setf (claude-bridge-review-display-buffer review) nil)
    (when buffer
      (remhash buffer *claude-bridge-review-buffers*)
      (when (claude-bridge-live-buffer-p buffer)
        (ignore-errors (delete-buffer buffer))))))

(defun claude-bridge-release-review (review)
  (claude-bridge-close-review-buffer review)
  (setf (claude-bridge-review-buffer review) nil
        (claude-bridge-review-original review) nil
        (claude-bridge-review-proposed review) nil))

(defun claude-bridge-stop ()
  "Stop the owned MCP server and remove private session state."
  (maphash (lambda (id review)
             (declare (ignore id))
             (when (eq :pending (claude-bridge-review-status review))
               (setf (claude-bridge-review-status review) :rejected))
             (claude-bridge-release-review review))
           *claude-bridge-reviews*)
  (clrhash *claude-bridge-reviews*)
  (clrhash *claude-bridge-review-buffers*)
  (when (and *claude-bridge-server*
             (eq *claude-bridge-server*
                 (lem-mcp-server:current-mcp-server)))
    (ignore-errors
      (lem-mcp-server:stop-mcp-server *claude-bridge-server*)))
  (when *claude-bridge-config-pathname*
    (ignore-errors (delete-file *claude-bridge-config-pathname*)))
  (setf *claude-bridge-server* nil
        *claude-bridge-token* nil
        *claude-bridge-config-pathname* nil
        lem-mcp-server:*mcp-server-auth-token* nil)
  t)

(defun claude-bridge-tool-argument (arguments name)
  (cdr (assoc name arguments :test #'string=)))

(defun claude-bridge-review-target (arguments)
  (let ((buffer-name (claude-bridge-tool-argument arguments "buffer_name"))
        (old-path (claude-bridge-tool-argument arguments "old_file_path")))
    (or (and (stringp buffer-name) (get-buffer buffer-name))
        (and (stringp old-path)
             (plusp (length old-path))
             (find-file-buffer old-path))
        (lem-mcp-server::mcp-error
         lem-mcp-server::+invalid-params+
         "openDiff requires buffer_name or old_file_path"))))

(defun claude-bridge-supersede-buffer-reviews (buffer)
  (maphash
   (lambda (id review)
     (declare (ignore id))
     (when (and (eq buffer (claude-bridge-review-buffer review))
                (eq :pending (claude-bridge-review-status review)))
       (setf (claude-bridge-review-status review) :superseded)
       (claude-bridge-release-review review)))
   *claude-bridge-reviews*))

(defun claude-bridge-prune-reviews ()
  (when (>= (hash-table-count *claude-bridge-reviews*)
            *claude-bridge-review-limit*)
    (let ((finished '()))
      (maphash
       (lambda (id review)
         (unless (eq :pending (claude-bridge-review-status review))
           (push (cons (parse-integer id) id) finished)))
       *claude-bridge-reviews*)
      (dolist (entry (sort finished #'< :key #'car))
        (when (< (hash-table-count *claude-bridge-reviews*)
                 *claude-bridge-review-limit*)
          (return))
        (remhash (cdr entry) *claude-bridge-reviews*)))
    (when (>= (hash-table-count *claude-bridge-reviews*)
              *claude-bridge-review-limit*)
      (lem-mcp-server::mcp-error
       lem-mcp-server::+server-error+ "Too many pending Claude reviews"))))

(defun claude-bridge-review-title (title)
  (let ((title (if (and (stringp title) (plusp (length title)))
                   title
                   "Claude proposal")))
    (unless (and (<= (length title) 256)
                 (every (lambda (character)
                          (not (or (char= character #\Newline)
                                   (char= character #\Return)
                                   (char= character #\Null))))
                        title))
      (lem-mcp-server::mcp-error
       lem-mcp-server::+invalid-params+ "Invalid Claude review title"))
    title))

(define-major-mode claude-bridge-review-mode ()
    (:name "Claude-Review"
     :keymap *claude-bridge-review-mode-keymap*
     :description "Review a Claude Code buffer proposal. y accepts; q rejects.")
  (setf (buffer-read-only-p (current-buffer)) t))

(defmethod lem-vi-mode/core:mode-specific-keymaps
    ((mode claude-bridge-review-mode))
  (list *claude-bridge-review-mode-keymap*))

(defun claude-bridge-open-review (buffer proposed title)
  (when (buffer-read-only-p buffer)
    (lem-mcp-server::mcp-error
     lem-mcp-server::+invalid-params+ "The target buffer is read-only"))
  (let ((original (buffer-text buffer)))
    (when (or (> (length original) *claude-bridge-review-input-limit*)
              (> (length proposed) *claude-bridge-review-input-limit*))
      (lem-mcp-server::mcp-error
       lem-mcp-server::+invalid-params+ "The proposed diff exceeds 16 MiB"))
    (when (string= original proposed)
      (return-from claude-bridge-open-review
        "{\"status\":\"unchanged\"}"))
    (claude-bridge-supersede-buffer-reviews buffer)
    (claude-bridge-prune-reviews)
    (let* ((id (princ-to-string (incf *claude-bridge-review-counter*)))
           (review
             (make-instance 'claude-bridge-review
                            :id id
                            :buffer buffer
                            :tick (buffer-modified-tick buffer)
                            :original original
                            :proposed proposed))
           (display
             (make-buffer (format nil "*Claude Review ~A*" id)
                          :enable-undo-p nil))
           (diff
             (vundo-unified-diff
              original proposed
              (or (and (buffer-filename buffer)
                       (uiop:native-namestring (buffer-filename buffer)))
                  (buffer-name buffer))
              (claude-bridge-review-title title))))
      (change-buffer-mode display 'claude-bridge-review-mode)
      (buffer-disable-undo display)
      (with-buffer-read-only display nil
        (erase-buffer display)
        (insert-string
         (buffer-start-point display)
         (format nil
                 "Claude proposal for ~A~%Review ~A — y accept, q reject~%~%~A"
                 (buffer-name buffer) id diff)))
      (move-point (buffer-point display) (buffer-start-point display))
      (setf (claude-bridge-review-display-buffer review) display
            (gethash id *claude-bridge-reviews*) review
            (gethash display *claude-bridge-review-buffers*) review)
      (switch-to-buffer display)
      (format nil
              "{\"review_id\":\"~A\",\"status\":\"pending\",\"instruction\":\"Wait for the user, then call checkDiff\"}"
              id))))

(defun claude-bridge-open-diff-tool (arguments)
  (let ((proposed
          (or (claude-bridge-tool-argument arguments "new_file_contents")
              (claude-bridge-tool-argument arguments "new_content")))
        (title (claude-bridge-tool-argument arguments "tab_name")))
    (unless (stringp proposed)
      (lem-mcp-server::mcp-error
       lem-mcp-server::+invalid-params+ "openDiff requires new_file_contents"))
    (claude-bridge-open-review
     (claude-bridge-review-target arguments) proposed title)))

(defun claude-bridge-check-diff-tool (arguments)
  (let* ((id (claude-bridge-tool-argument arguments "review_id"))
         (review (and (stringp id) (gethash id *claude-bridge-reviews*))))
    (unless review
      (lem-mcp-server::mcp-error
       lem-mcp-server::+invalid-params+ "Unknown Claude review id"))
    (format nil "{\"review_id\":\"~A\",\"status\":\"~A\"}"
            id
            (string-downcase
             (symbol-name (claude-bridge-review-status review))))))

(defun claude-bridge-current-review ()
  (or (gethash (current-buffer) *claude-bridge-review-buffers*)
      (editor-error "This is not an active Claude review")))

(defun claude-bridge-finish-review (review status)
  (setf (claude-bridge-review-status review) status)
  (let ((source (claude-bridge-review-buffer review)))
    (when (claude-bridge-live-buffer-p source)
      (switch-to-buffer source)))
  (claude-bridge-release-review review)
  (message "Claude proposal ~A" (string-downcase (symbol-name status))))

(define-command claude-bridge-review-accept () ()
  "Accept the active Claude proposal as one retained undo transaction."
  (let* ((review (claude-bridge-current-review))
         (buffer (claude-bridge-review-buffer review)))
    (unless (and (claude-bridge-live-buffer-p buffer)
                 (= (claude-bridge-review-tick review)
                    (buffer-modified-tick buffer))
                 (string= (claude-bridge-review-original review)
                          (buffer-text buffer)))
      (claude-bridge-finish-review review :stale)
      (editor-error "Claude proposal is stale; the target buffer changed"))
    (formatting-apply-output
     buffer
     (claude-bridge-review-original review)
     (claude-bridge-review-proposed review))
    (claude-bridge-finish-review review :accepted)))

(define-command claude-bridge-review-reject () ()
  "Reject the active Claude proposal without changing its target buffer."
  (claude-bridge-finish-review (claude-bridge-current-review) :rejected))

(define-key *claude-bridge-review-mode-keymap* "y"
  'claude-bridge-review-accept)
(define-key *claude-bridge-review-mode-keymap* "q"
  'claude-bridge-review-reject)
(define-key *claude-bridge-review-mode-keymap* "Escape"
  'claude-bridge-review-reject)

(defun claude-bridge-register-tools ()
  (lem-mcp-server::register-tool
   "openDiff"
   "Open a user-controlled diff in Lem. No edit occurs until the user accepts it."
   '(("type" . "object")
     ("properties"
      . (("buffer_name" . (("type" . "string")))
         ("old_file_path" . (("type" . "string")))
         ("new_file_path" . (("type" . "string")))
         ("new_file_contents" . (("type" . "string")))
         ("tab_name" . (("type" . "string")))))
     ("required" . ("new_file_contents")))
   #'claude-bridge-open-diff-tool)
  (lem-mcp-server::register-tool
   "checkDiff"
   "Return whether a Lem diff review is pending, accepted, rejected, or stale."
   '(("type" . "object")
     ("properties"
      . (("review_id" . (("type" . "string")))))
     ("required" . ("review_id")))
   #'claude-bridge-check-diff-tool))

(defun claude-bridge-allowed-tools ()
  (concatenate
   'string
   "mcp__lem__buffer_list,mcp__lem__buffer_get_content,"
   "mcp__lem__buffer_info,mcp__lem__editor_get_screen,"
   "mcp__lem__openDiff,mcp__lem__checkDiff"))

(define-command lem-yath-claude-bridge-start () ()
  "Start the authenticated local Claude/Lem MCP bridge."
  (let ((pathname (claude-bridge-start)))
    (message "Claude bridge ready; private config: ~A" pathname)))

(define-command lem-yath-claude-bridge-stop () ()
  "Stop the Claude/Lem MCP bridge and remove its private config."
  (claude-bridge-stop)
  (message "Claude bridge stopped"))

(define-command lem-yath-claude-bridge-status () ()
  "Report whether the authenticated Claude/Lem MCP bridge is running."
  (if (claude-bridge-server-live-p)
      (message "Claude bridge is running on 127.0.0.1:~D"
               (lem-mcp-server:mcp-server-port *claude-bridge-server*))
      (message "Claude bridge is stopped")))

(claude-bridge-register-tools)
(remove-hook *exit-editor-hook* 'claude-bridge-stop)
(add-hook *exit-editor-hook* 'claude-bridge-stop)
