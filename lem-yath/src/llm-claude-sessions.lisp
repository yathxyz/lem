;;;; Project-scoped Claude Code session forking and selection.

(in-package :lem-yath)

(defparameter *llm-claude-session-file-limit* (* 64 1024 1024))
(defparameter *llm-claude-session-index-limit* (* 8 1024 1024))
(defparameter *llm-claude-message-id-limit* 256)
(defvar *llm-claude-projects-directory-override* nil)

(defun llm-claude-projects-directory ()
  (uiop:ensure-directory-pathname
   (or *llm-claude-projects-directory-override*
       (uiop:getenv "LEM_YATH_CLAUDE_PROJECTS_DIR")
       (merge-pathnames ".claude/projects/" (user-homedir-pathname)))))

(defun llm-claude-message-id-valid-p (message-id)
  (and (stringp message-id)
       (plusp (length message-id))
       (<= (length message-id) *llm-claude-message-id-limit*)
       (every (lambda (character)
                (and (graphic-char-p character)
                     (not (member character '(#\Newline #\Return #\Tab)))))
              message-id)))

(defun llm-claude-safe-owned-directory-p (pathname)
  #+sbcl
  (handler-case
      (let ((stat (sb-posix:lstat (uiop:native-namestring pathname))))
        (and (= (logand (sb-posix:stat-mode stat) sb-posix:s-ifmt)
                sb-posix:s-ifdir)
             (= (sb-posix:stat-uid stat) (sb-posix:getuid))
             (zerop (logand (sb-posix:stat-mode stat) #o022))))
    (error () nil))
  #-sbcl
  nil)

(defun llm-claude-safe-owned-file-p (pathname)
  #+sbcl
  (handler-case
      (let ((stat (sb-posix:lstat (uiop:native-namestring pathname))))
        (and (= (logand (sb-posix:stat-mode stat) sb-posix:s-ifmt)
                sb-posix:s-ifreg)
             (= (sb-posix:stat-uid stat) (sb-posix:getuid))
             (zerop (logand (sb-posix:stat-mode stat) #o022))))
    (error () nil))
  #-sbcl
  nil)

(defun llm-claude-unsafe-working-directory-p (pathname)
  (let ((root (ignore-errors (truename #P"/")))
        (home (ignore-errors (truename (user-homedir-pathname)))))
    (or (and root (uiop:pathname-equal pathname root))
        (and home (uiop:pathname-equal pathname home)))))

(defun llm-claude-project-root (&optional (buffer (current-buffer)))
  (let* ((directory (or (buffer-directory buffer) (uiop:getcwd)))
         (root (and directory
                    (lem-yath-project-root-for-directory directory))))
    (unless root
      (editor-error "Claude session history requires a local Git project"))
    (let ((root
            (or (ignore-errors (truename root))
                (editor-error "Claude project root is unavailable: ~a" root))))
      (when (llm-claude-unsafe-working-directory-p root)
        (editor-error "Refusing unsafe Claude working directory: ~a" root))
      root)))

(defun llm-claude-mcp-config-pathname (project-root)
  "Return the first safe configured Claude MCP file for PROJECT-ROOT."
  (find-if
   #'llm-claude-safe-owned-file-p
   (list (merge-pathnames ".mcp.json"
                          (uiop:ensure-directory-pathname project-root))
         (merge-pathnames ".claude/.mcp.json"
                          (user-homedir-pathname)))))

(defun llm-claude-encoded-project-path (root)
  "Encode ROOT like Claude Code's ~/.claude/projects directory names."
  (cl-ppcre:regex-replace-all
   "[/.]"
   (string-right-trim '(#\/) (uiop:native-namestring root))
   "-"))

(defun llm-claude-session-directory (&optional (buffer (current-buffer)))
  (let* ((projects (llm-claude-projects-directory))
         (root (llm-claude-project-root buffer))
         (directory
           (merge-pathnames
            (format nil "~a/" (llm-claude-encoded-project-path root))
            projects)))
    (unless (and (llm-claude-safe-owned-directory-p projects)
                 (llm-claude-safe-owned-directory-p directory))
      (editor-error
       "Claude project history must be an owned, non-writable directory: ~a"
       directory))
    (values directory root)))

(defun llm-claude-session-pathname (directory session-id)
  (unless (llm-cli-session-id-valid-p session-id)
    (editor-error "Invalid Claude session id"))
  (merge-pathnames (format nil "~a.jsonl" session-id) directory))

(defun llm-claude-regular-owned-file-stat (pathname limit)
  #+sbcl
  (handler-case
      (let ((stat (sb-posix:lstat (uiop:native-namestring pathname))))
        (unless (and (= (logand (sb-posix:stat-mode stat) sb-posix:s-ifmt)
                        sb-posix:s-ifreg)
                     (= (sb-posix:stat-uid stat) (sb-posix:getuid))
                     (zerop (logand (sb-posix:stat-mode stat) #o022))
                     (<= (sb-posix:stat-size stat) limit))
          (editor-error "Claude history file is unsafe or oversized: ~a"
                        pathname))
        stat)
    (sb-posix:syscall-error ()
      (editor-error "Claude history file is unavailable: ~a" pathname)))
  #-sbcl
  (declare (ignore pathname limit))
  #-sbcl
  (editor-error "Safe Claude session handling requires SBCL"))

(defun llm-claude-read-json-file (pathname limit)
  (llm-claude-regular-owned-file-stat pathname limit)
  (handler-case
      (with-open-file (stream pathname
                              :direction :input
                              :external-format :utf-8)
        (yason:parse stream))
    (error () (editor-error "Malformed Claude session index: ~a" pathname))))

(defun llm-claude-truncated-session-lines (pathname message-id)
  "Read PATHNAME through the JSONL record whose uuid is MESSAGE-ID."
  (unless (llm-claude-message-id-valid-p message-id)
    (editor-error "Invalid Claude message id"))
  (llm-claude-regular-owned-file-stat
   pathname *llm-claude-session-file-limit*)
  (let ((lines nil)
        (found-p nil))
    (handler-case
        (with-open-file (stream pathname
                                :direction :input
                                :external-format :utf-8)
          (loop :for line := (read-line stream nil)
                :while line
                :do
                   (when (> (length line) *llm-cli-line-limit*)
                     (editor-error "Claude history contains an oversized record"))
                   (push line lines)
                   (let ((json (handler-case (yason:parse line)
                                 (error () nil))))
                     (when (and (hash-table-p json)
                                (equal (gethash "uuid" json) message-id))
                       (setf found-p t)
                       (return)))))
      (editor-error (condition) (error condition))
      (error ()
        (editor-error "Could not read Claude session: ~a" pathname)))
    (unless found-p
      (editor-error "Claude message ~a is absent from session history"
                    message-id))
    (nreverse lines)))

(defun llm-claude-open-private-output (pathname)
  #+sbcl
  (let ((descriptor
          (sb-posix:open
           (uiop:native-namestring pathname)
           (logior sb-posix:o-creat sb-posix:o-excl
                   sb-posix:o-wronly sb-posix:o-nofollow)
           #o600)))
    (handler-case
        (progn
          (sb-posix:fchmod descriptor #o600)
          (values
           (sb-sys:make-fd-stream
            descriptor :output t :element-type 'character
            :external-format :utf-8 :buffering :full
            :name (uiop:native-namestring pathname))
           descriptor))
      (error (condition)
        (ignore-errors (sb-posix:close descriptor))
        (ignore-errors (delete-file pathname))
        (error condition))))
  #-sbcl
  (declare (ignore pathname))
  #-sbcl
  (editor-error "Safe Claude session handling requires SBCL"))

(defun llm-claude-write-exclusive-lines (pathname lines)
  (let ((stream nil)
        (descriptor nil)
        (complete-p nil))
    (unwind-protect
         (progn
           (multiple-value-setq (stream descriptor)
             (llm-claude-open-private-output pathname))
           (dolist (line lines) (write-line line stream))
           (finish-output stream)
           #+sbcl (sb-posix:fsync descriptor)
           (close stream)
           (setf stream nil descriptor nil complete-p t))
      (when stream
        (ignore-errors (close stream :abort t))
        (setf descriptor nil))
      (when descriptor
        #+sbcl (ignore-errors (sb-posix:close descriptor)))
      (unless complete-p
        (ignore-errors (delete-file pathname))))))

(defun llm-claude-temporary-pathname (pathname)
  (uiop:parse-native-namestring
   (format nil "~a.tmp.~d.~16,'0x"
           (uiop:native-namestring pathname)
           #+sbcl (sb-posix:getpid)
           #-sbcl 0
           (random (ash 1 60)))))

(defun llm-claude-write-json-atomically (pathname object)
  (let ((temporary (llm-claude-temporary-pathname pathname))
        (stream nil)
        (descriptor nil))
    (unwind-protect
         (progn
           (multiple-value-setq (stream descriptor)
             (llm-claude-open-private-output temporary))
           (yason:encode object stream)
           (terpri stream)
           (finish-output stream)
           #+sbcl (sb-posix:fsync descriptor)
           (close stream)
           (setf stream nil descriptor nil)
           (uiop:rename-file-overwriting-target temporary pathname)
           #+sbcl
           (sb-posix:chmod (uiop:native-namestring pathname) #o600))
      (when stream
        (ignore-errors (close stream :abort t))
        (setf descriptor nil))
      (when descriptor
        #+sbcl (ignore-errors (sb-posix:close descriptor)))
      (when (uiop:file-exists-p temporary)
        (ignore-errors (delete-file temporary))))))

(defun llm-claude-utc-timestamp ()
  (multiple-value-bind (second minute hour day month year)
      (decode-universal-time (get-universal-time) 0)
    (format nil "~4,'0d-~2,'0d-~2,'0dT~2,'0d:~2,'0d:~2,'0dZ"
            year month day hour minute second)))

(defun llm-claude-session-index (directory root)
  (let ((pathname (merge-pathnames "sessions-index.json" directory)))
    (if (uiop:file-exists-p pathname)
        (let ((object
                (llm-claude-read-json-file
                 pathname *llm-claude-session-index-limit*)))
          (unless (hash-table-p object)
            (editor-error "Claude session index is not a JSON object"))
          object)
        (llm-json-object
         "version" 1 "entries" #()
         "originalPath" (uiop:native-namestring root)))))

(defun llm-claude-index-entries (index)
  (let ((entries (and (hash-table-p index) (gethash "entries" index))))
    (unless (or (null entries) (listp entries) (vectorp entries))
      (editor-error "Claude session index entries are malformed"))
    (let ((entries (llm-cli-sequence-list entries)))
      (unless (every #'hash-table-p entries)
        (editor-error "Claude session index contains a malformed entry"))
      entries)))

(defun llm-claude-register-fork
    (directory root session-id pathname source-session-id line-count)
  (let* ((index-pathname (merge-pathnames "sessions-index.json" directory))
         (index (llm-claude-session-index directory root))
         (entries (llm-claude-index-entries index))
         (now (llm-claude-utc-timestamp))
         (entry
           (llm-json-object
            "sessionId" session-id
            "fullPath" (uiop:native-namestring pathname)
            "firstPrompt" (format nil "Fork of ~a" source-session-id)
            "summary" (format nil "Fork of ~a" source-session-id)
            "messageCount" line-count
            "created" now
            "modified" now
            "isSidechain" yason:false)))
    (setf (gethash "entries" index)
          (coerce (append entries (list entry)) 'vector))
    (llm-claude-write-json-atomically index-pathname index)))

(defun llm-claude-call-with-session-lock (directory function)
  #+sbcl
  (let* ((pathname (merge-pathnames ".lem-yath-session.lock" directory))
         (descriptor
           (sb-posix:open
            (uiop:native-namestring pathname)
            (logior sb-posix:o-creat sb-posix:o-rdwr sb-posix:o-nofollow)
            #o600)))
    (unwind-protect
         (progn
           (sb-posix:fchmod descriptor #o600)
           (let ((stat (sb-posix:fstat descriptor)))
             (unless (and (= (logand (sb-posix:stat-mode stat)
                                     sb-posix:s-ifmt)
                             sb-posix:s-ifreg)
                          (= (sb-posix:stat-uid stat) (sb-posix:getuid)))
               (editor-error "Unsafe Claude session lock")))
           (sb-posix:lockf descriptor sb-posix:f-lock 0)
           (funcall function))
      (ignore-errors (sb-posix:lockf descriptor sb-posix:f-ulock 0))
      (ignore-errors (sb-posix:close descriptor))))
  #-sbcl
  (declare (ignore directory function))
  #-sbcl
  (editor-error "Safe Claude session handling requires SBCL"))

(defun llm-claude-create-session-fork
    (directory root source-session-id message-id)
  "Create and register a private Claude fork through MESSAGE-ID."
  (llm-claude-call-with-session-lock
   directory
   (lambda ()
     (let* ((source
              (llm-claude-session-pathname directory source-session-id))
            (lines (llm-claude-truncated-session-lines source message-id))
            (new-id nil)
            (target nil))
       (loop
         (setf new-id (uuid-v4)
               target (llm-claude-session-pathname directory new-id))
         (unless (uiop:file-exists-p target) (return)))
       (setf lines
             (append
              lines
              (list
               (llm-cli-json-string
                (llm-json-object
                 "type" "last-prompt"
                 "sessionId" new-id
                 "lastPrompt" "fork")))))
       (llm-claude-write-exclusive-lines target lines)
       (handler-case
           (progn
             (llm-claude-register-fork
              directory root new-id target source-session-id (1- (length lines)))
             new-id)
         (error (condition)
           (ignore-errors (delete-file target))
           (error condition)))))))

(defun llm-claude-response-state-at-or-before (point)
  "Return the nearest response state at or before POINT."
  (let ((buffer (point-buffer point)))
    (with-point ((probe point)
                 (start (buffer-start-point buffer))
                 (end (buffer-end-point buffer)))
      (when (and (point= probe end) (point< start probe))
        (character-offset probe -1))
      (loop
        (alexandria:when-let
            ((state (text-property-at probe *llm-response-state-key*)))
          (return state))
        (when (point= probe start) (return nil))
        (unless (previous-single-property-change
                 probe *llm-response-state-key* start)
          (move-point probe start))
        (when (point< start probe) (character-offset probe -1))))))

(defun llm-claude-nearest-response-state ()
  "Return the nearest response state at or before point."
  (llm-claude-response-state-at-or-before (current-point)))

(defun llm-claude-response-state-after-point (point)
  "Return the nearest Claude response state starting after POINT."
  (let ((buffer (point-buffer point)))
    (with-point ((probe point)
                 (end (buffer-end-point buffer)))
      (loop
        (when (point< probe end)
          (alexandria:when-let
              ((state (text-property-at probe *llm-response-state-key*)))
            (when (eq (llm-response-state-backend state) :claude-code)
              (return state))))
        (unless (and (point< probe end)
                     (next-single-property-change
                      probe *llm-response-state-key* end))
          (return nil))))))

(defun llm-claude-response-state-before (point)
  "Return the nearest response state strictly before POINT."
  (let ((buffer (point-buffer point)))
    (with-point ((probe point)
                 (start (buffer-start-point buffer)))
      (when (point< start probe)
        (character-offset probe -1)
        (llm-claude-response-state-at-or-before probe)))))

(defun llm-claude-auto-fork-state (buffer origin)
  "Return the preceding state when ORIGIN requires a Claude fork.
A fresh or already divergent session remains authoritative."
  (when (and (llm-conversation-buffer-p buffer)
             origin
             (alive-point-p origin)
             (eq buffer (point-buffer origin)))
    (alexandria:when-let
        ((later-state (llm-claude-response-state-after-point origin)))
      (alexandria:when-let
          ((stored-session-id (llm-cli-session-id :claude-code buffer)))
        (let* ((state
                 (or (llm-claude-response-state-before origin)
                     (editor-error
                      "Cannot branch Claude without a preceding Assistant response")))
               (backend (llm-response-state-backend state))
               (session-id (llm-response-state-provider-session-id state))
               (later-session-id
                 (llm-response-state-provider-session-id later-state)))
          (unless (eq backend :claude-code)
            (editor-error
             "Cannot branch Claude from a non-Claude Assistant response"))
          (unless (llm-cli-session-id-valid-p session-id)
            (editor-error "The branch point has no resumable Claude session"))
          (unless (llm-cli-session-id-valid-p later-session-id)
            (editor-error "The later Claude response has no resumable session"))
          (when (and (equal stored-session-id session-id)
                     (equal later-session-id session-id))
            (unless (llm-claude-message-id-valid-p
                     (llm-response-state-provider-message-id state))
              (editor-error "The branch point has no Claude message boundary"))
            state))))))

(defun llm-claude-maybe-auto-fork-session (buffer origin)
  "Fork a Claude session when ORIGIN branches before a later response.
Return the new session id, or nil when this is an ordinary tail send."
  (alexandria:when-let ((state (llm-claude-auto-fork-state buffer origin)))
    (let ((session-id (llm-response-state-provider-session-id state))
          (message-id (llm-response-state-provider-message-id state)))
      (multiple-value-bind (directory root)
          (llm-claude-session-directory buffer)
        (let ((new-id
                (llm-claude-create-session-fork
                 directory root session-id message-id)))
          (llm-cli-store-session-id buffer :claude-code new-id)
          (message "Automatically forked Claude session ~a -> ~a"
                   session-id new-id)
          new-id)))))

(defun llm-claude-activate-backend ()
  "Make the selected Claude session the backend for the next send."
  (setf *llm-backend* :claude-code
        *llm-model* "claude-code"
        *llm-use-tools* nil)
  (when (boundp '*llm-mcp-server-names*)
    (setf (symbol-value '*llm-mcp-server-names*) nil))
  (llm-mark-settings-custom))

(define-command lem-yath-llm-claude-fork () ()
  "Fork the active Claude Code session at the preceding Assistant response."
  (unless (llm-conversation-buffer-p)
    (editor-error "Claude session forking requires an LLM conversation"))
  (when (llm-active-request (current-buffer))
    (editor-error "Wait for or abort the active LLM request first"))
  (let* ((buffer (current-buffer))
         (state (or (llm-claude-nearest-response-state)
                    (editor-error "No preceding Assistant response")))
         (backend (llm-response-state-backend state))
         (message-id (llm-response-state-provider-message-id state))
         (session-id
           (or (llm-response-state-provider-session-id state)
               (llm-cli-session-id :claude-code buffer))))
    (unless (eq backend :claude-code)
      (editor-error "The preceding response is not from Claude Code"))
    (unless (llm-cli-session-id-valid-p session-id)
      (editor-error "The response has no resumable Claude session"))
    (unless (llm-claude-message-id-valid-p message-id)
      (editor-error "The response has no Claude message boundary"))
    (multiple-value-bind (directory root)
        (llm-claude-session-directory buffer)
      (let ((new-id
              (llm-claude-create-session-fork
               directory root session-id message-id)))
        (llm-cli-store-session-id buffer :claude-code new-id)
        (llm-claude-activate-backend)
        (message "Forked Claude session ~a -> ~a" session-id new-id)))))

(defun llm-claude-session-candidates (directory root)
  (let* ((index (llm-claude-session-index directory root))
         (entries (llm-claude-index-entries index)))
    (loop :for entry :in entries
          :for session-id := (gethash "sessionId" entry)
          :when (llm-cli-session-id-valid-p session-id)
            :collect
            (cons
             (format nil "~a  ~a"
                     (or (gethash "modified" entry) "")
                     (or (gethash "firstPrompt" entry)
                         (gethash "summary" entry)
                         "?"))
             session-id))))

(define-command lem-yath-llm-claude-browse-sessions () ()
  "Select a Claude Code session for the current LLM conversation."
  (unless (llm-conversation-buffer-p)
    (editor-error "Claude session selection requires an LLM conversation"))
  (when (llm-active-request (current-buffer))
    (editor-error "Wait for or abort the active LLM request first"))
  (multiple-value-bind (directory root)
      (llm-claude-session-directory (current-buffer))
    (let ((candidates (llm-claude-session-candidates directory root)))
      (unless candidates
        (editor-error "No Claude sessions are registered for this project"))
      (let* ((labels (mapcar #'car candidates))
             (choice
               (prompt-for-string
                "Session: "
                :completion-function
                (lambda (string) (prescient-filter string labels))
                :history-symbol 'lem-yath-llm-claude-session))
             (session-id (cdr (assoc choice candidates :test #'string=))))
        (unless session-id
          (editor-error "Select a registered Claude session"))
        (llm-cli-store-session-id
         (current-buffer) :claude-code session-id)
        (llm-claude-activate-backend)
        (message "Claude session: ~a" session-id)))))

(define-key *lem-yath-llm-conversation-mode-keymap*
  "C-c C-f" 'lem-yath-llm-claude-fork)
(define-key *lem-yath-llm-conversation-mode-keymap*
  "C-c C-b" 'lem-yath-llm-claude-browse-sessions)
