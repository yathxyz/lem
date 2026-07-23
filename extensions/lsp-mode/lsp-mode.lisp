(defpackage :lem-lsp-mode/lsp-mode
  (:nicknames :lem-lsp-mode)
  (:use :cl
        :lem
        :alexandria
        :lem-lsp-base/type
        :lem-lsp-base/converter
        :lem-lsp-base/yason-utils
        :lem-lsp-base/utils
        :lem-lsp-mode/spec
        :lem/common/utils)
  (:shadow :execute-command)
  (:import-from :lem-language-client/request)
  (:import-from :lem/context-menu)
  (:local-nicknames (:client :lem-lsp-mode/client))
  (:local-nicknames (:request :lem-language-client/request))
  (:local-nicknames (:completion :lem/completion-mode))
  (:local-nicknames (:context-menu :lem/context-menu))
  (:local-nicknames (:spinner :lem/loading-spinner))
  (:local-nicknames (:language-mode :lem/language-mode))
  (:export :*inhibit-highlight-diagnotics*
           :get-buffer-from-text-document-identifier
           :spec-workspace-configuration
           :spec-initialization-options
           :register-lsp-method
           :define-language-spec
           :without-lsp-mode))
(in-package :lem-lsp-mode/lsp-mode)

;; FIXME:
;; dirty hack.
;; Ideally, improve lsp-mode to work within markdown code blocks.
(defvar *disable* nil
  "This variable is used to temporarily disable lsp-mode.
Its purpose is to disable lsp-mode in a code block within markdown-mode, which can cause unexpected behavior in lsp-mode.
Setting this variable to T while working within a markdown code block will avoid this problem.")

(defmacro without-lsp-mode (() &body body)
  "This macro prevents enabling lsp-mode within the body.
Use this when lsp-mode has side effects that you want to avoid."
  `(let ((*disable* (current-buffer)))
     ,@body))

;;;
(define-condition not-found-program (editor-error)
  ((name :initarg :name
         :initform (required-argument :name)
         :reader not-found-program-name)
   (spec :initarg :spec
         :initform (required-argument :spec)
         :reader not-found-program-spec))
  (:report (lambda (c s)
             (with-slots (name spec) c
               (format s (gen-install-help-message name spec))))))

(defun gen-install-help-message (program spec)
  (with-output-to-string (out)
    (format out "\"~A\" is not installed." program)
    (when (spec-install-command spec)
      (format out
              "~&You can install it with the following command.~2% $ ~A"
              (spec-install-command spec)))
    (when (spec-readme-url spec)
      (format out "~&~%See follow for the readme URL~2% ~A ~%" (spec-readme-url spec)))))

(defun check-exist-program (program spec)
  (unless (exist-program-p program)
    (error 'not-found-program :name program :spec spec)))

;;;
(defun server-process-buffer-name (spec)
  (format nil "*Lsp <~A>*" (spec-language-id spec)))

(defmethod run-server-using-mode ((mode (eql :tcp)) spec &key directory)
  (flet ((output-callback (string)
           (let* ((buffer (make-buffer (server-process-buffer-name spec)))
                  (point (buffer-point buffer)))
             (buffer-end point)
             (insert-string point string))))
    (let* ((port (or (spec-port spec) (lem/common/socket:random-available-port)))
           (process (when-let (command (get-spec-command spec port))
                      (check-exist-program (first command) spec)
                      (lem-process:run-process command
                                               :directory directory
                                               :output-callback #'output-callback))))
      (make-instance 'client:tcp-client :process process :port port))))

(defmethod run-server-using-mode ((mode (eql :stdio)) spec &key directory)
  (let ((command (get-spec-command spec)))
    (check-exist-program (first command) spec)
    (let ((process
            (uiop:launch-program
             (append '("bash" "-c"
                       "exec \"$@\" 2>>\"${LEM_YATH_LSP_STDERR:-/dev/null}\""
                       "lem-lsp-stdio")
                     command)
             :directory directory
             :input :stream
             :output :stream
             :error-output :interactive
             :external-format :utf-8)))
      (make-instance 'client:stdio-client :process process))))

(defmethod run-server (spec &key directory)
  (run-server-using-mode (spec-connection-mode spec)
                         spec
                         :directory directory))

;;;
(defmacro with-jsonrpc-error (() &body body)
  (with-unique-names (c)
    `(handler-case (progn ,@body)
       (jsonrpc/errors:jsonrpc-callback-error (,c)
         (editor-error "~A" ,c)))))

(defun jsonrpc-editor-error (message code)
  (editor-error "JSONRPC-CALLBACK-ERROR: ~A (Code=~A)" message code))

(defun async-request (client request params &key then error)
  (request:request-async client
                         request
                         params
                         (lambda (response)
                           (send-event (lambda () (funcall then response))))
                         (lambda (message code)
                           (send-event
                            (lambda ()
                              (if error
                                  (funcall error message code)
                                  (jsonrpc-editor-error message code)))))))

(defun display-message (text &key style source-window)
  (when text
    (show-message text
                  :style style
                  :timeout nil
                  :source-window source-window)))

(defun make-temporary-unwrap-buffer ()
  (let ((buffer (make-buffer nil :temporary t :enable-undo-p nil)))
    (setf (variable-value 'lem:line-wrap :buffer buffer) nil)
    buffer))

;;;
(defun buffer-language-spec (buffer)
  (get-language-spec (language-mode:buffer-language-mode buffer)))

(defun buffer-language-id (buffer)
  (when-let (spec (buffer-language-spec buffer))
    (spec-language-id spec)))

(defun buffer-version (buffer)
  (buffer-modified-tick buffer))

(defun buffer-uri (buffer)
  ;; TODO: lem-language-server::buffer-uri
  (if (buffer-filename buffer)
      (pathname-to-uri (buffer-filename buffer))
      (format nil "buffer://~A" (buffer-name buffer))))

(defgeneric compute-root-pathname (spec buffer)
  (:method (spec buffer)
    (let ((root (language-mode:find-root-directory
                 (buffer-directory buffer)
                 (spec-root-uri-patterns spec))))
      (uiop:ensure-directory-pathname
       (or (ignore-errors (truename root)) root)))))

(defun compute-root-uri (spec buffer)
  (pathname-to-uri (compute-root-pathname spec buffer)))

;;;
(defclass workspace ()
  ((root-uri
    :initarg :root-uri
    :initform nil
    :accessor workspace-root-uri)
   (root-pathname
    :initarg :root-pathname
    :initform nil
    :accessor workspace-root-pathname)
   (key
    :initarg :key
    :initform nil
    :accessor workspace-key)
   (client
    :initarg :client
    :initform nil
    :accessor workspace-client)
   (spec
    :initarg :spec
    :initform nil
    :accessor workspace-spec)
   (server-capabilities
    :initarg :server-capabilities
    :initform nil
    :accessor workspace-server-capabilities)
   (server-info
    :initarg :server-info
    :initform nil
    :accessor workspace-server-info)
   (trigger-characters
    :initarg :trigger-characters
    :initform (make-hash-table)
    :accessor workspace-trigger-characters)
   (state
    :initarg :state
    :initform :starting
    :accessor workspace-state)
   (buffers
    :initarg :buffers
    :initform nil
    :accessor workspace-buffers)
   (pending-continuations
    :initarg :pending-continuations
    :initform nil
    :accessor workspace-pending-continuations)
   (initialization-timer
    :initarg :initialization-timer
    :initform nil
    :accessor workspace-initialization-timer)
   (startup-spinner
    :initarg :startup-spinner
    :initform nil
    :accessor workspace-startup-spinner)
   (initialization-options
    :initarg :initialization-options
    :initform nil
    :accessor workspace-initialization-options)
   (configuration
    :initarg :configuration
    :initform nil
    :accessor workspace-configuration)
   (progress-reports
    :initform (make-hash-table :test 'equal)
    :accessor workspace-progress-reports)
   (progress-removal-timers
    :initform (make-hash-table :test 'equal)
    :accessor workspace-progress-removal-timers)
   (plist
    :initarg :plist
    :initform nil
    :accessor workspace-plist)))

(defun make-workspace (&key spec client buffer)
  (let ((root (compute-root-pathname spec buffer)))
    (make-instance 'workspace
                   :spec spec
                   :client client
                   :root-pathname root
                   :root-uri (pathname-to-uri root)
                   :key (make-workspace-key spec root)
                   :initialization-options
                   (with-current-buffer buffer
                     (spec-initialization-options spec))
                   :configuration
                   (with-current-buffer buffer
                     (spec-workspace-configuration spec)))))

(defun workspace-value (workspace key &optional default)
  (getf (workspace-plist workspace) key default))

(defun (setf workspace-value) (value workspace key &optional default)
  (declare (ignore default))
  (setf (getf (workspace-plist workspace) key) value))

(defun workspace-language-id (workspace)
  (spec-language-id (workspace-spec workspace)))

(defgeneric make-workspace-key (spec root-pathname)
  (:method (spec root-pathname)
    (list (class-name (class-of spec))
          (namestring root-pathname))))

(defun workspace-registry-key (workspace)
  (workspace-key workspace))

(defvar *workspace-table*)

(defun current-workspace-entry-p (workspace)
  (eq workspace
      (gethash (workspace-registry-key workspace) *workspace-table*)))

(defun get-workspace-from-point (point)
  (buffer-workspace (point-buffer point)))

(defun set-trigger-characters (workspace)
  (dolist (character (get-completion-trigger-characters workspace))
    (setf (gethash character (workspace-trigger-characters workspace))
          #'completion-with-trigger-character))
  (dolist (character (get-signature-help-trigger-characters workspace))
    (setf (gethash character (workspace-trigger-characters workspace))
          #'lsp-signature-help-with-trigger-character)))

;;;
(defvar *workspace-table* (make-hash-table :test 'equal))
(defvar *workspace-list-per-language-id* (make-hash-table :test 'equal))
(defparameter *workspace-shutdown-timeout* 1)
(defparameter *workspace-initialize-timeout* 30)

(defgeneric find-workspace-for-buffer (spec buffer)
  (:method (spec buffer)
    (gethash (make-workspace-key spec (compute-root-pathname spec buffer))
             *workspace-table*)))

(defgeneric workspace-matches-buffer-p (workspace spec buffer)
  (:method (workspace spec buffer)
    (equal (workspace-key workspace)
           (make-workspace-key spec (compute-root-pathname spec buffer)))))

(defstruct workspace-list
  current-workspace
  workspaces)

(defun add-workspace (workspace)
  (setf (gethash (workspace-registry-key workspace) *workspace-table*)
        workspace)
  (if-let (workspace-list (gethash (workspace-language-id workspace)
                                   *workspace-list-per-language-id*))
    (progn
      (setf (workspace-list-current-workspace workspace-list) workspace)
      (pushnew workspace (workspace-list-workspaces workspace-list)))
    (setf (gethash (workspace-language-id workspace)
                   *workspace-list-per-language-id*)
          (make-workspace-list :current-workspace workspace
                               :workspaces (list workspace))))
  workspace)

(defun remove-workspace (workspace)
  (let ((key (workspace-registry-key workspace)))
    (when (eq workspace (gethash key *workspace-table*))
      (remhash key *workspace-table*)))
  (let* ((language-id (workspace-language-id workspace))
         (workspace-list (gethash language-id
                                  *workspace-list-per-language-id*)))
    (when workspace-list
      (setf (workspace-list-workspaces workspace-list)
            (delete workspace (workspace-list-workspaces workspace-list)))
      (when (eq workspace
                (workspace-list-current-workspace workspace-list))
        (setf (workspace-list-current-workspace workspace-list)
              (first (workspace-list-workspaces workspace-list))))
      (when (null (workspace-list-workspaces workspace-list))
        (remhash language-id *workspace-list-per-language-id*))))
  workspace)

(defun change-workspace (workspace)
  (let ((workspace-list (gethash (workspace-language-id workspace)
                                 *workspace-list-per-language-id*)))
    (assert workspace-list)
    (setf (workspace-list-current-workspace workspace-list) workspace)
    (reassign-language-workspace workspace)))

(defun find-workspace (language-id &key (errorp t))
  ;; A nil LANGUAGE-ID means the buffer's current major mode has no
  ;; registered language spec (e.g. a REPL mode whose parent had one).
  ;; That is not an error condition -- the buffer simply does not
  ;; participate in LSP.  Return nil silently regardless of ERRORP.
  (when language-id
    (if-let (workspace-list (gethash language-id *workspace-list-per-language-id*))
      (workspace-list-current-workspace workspace-list)
      (when errorp
        (error "The ~A workspace is not found." language-id)))))

(defun buffer-opened-uri (buffer)
  (buffer-value buffer 'lsp-opened-uri))

(defun lsp-buffer-attachment-valid-p (buffer workspace)
  (let ((spec (buffer-language-spec buffer))
        (state (buffer-value buffer 'lsp-state)))
    (and (not (deleted-buffer-p buffer))
         (mode-active-p buffer 'lsp-mode)
         (lsp-buffer-eligible-p buffer)
         spec
         (workspace-matches-buffer-p workspace spec buffer)
         (or (eq state :pending)
             (and (eq state :open)
                  (equal (buffer-opened-uri buffer)
                         (buffer-uri buffer)))))))

(defun workspace-response-current-p (workspace buffer)
  (and (typep workspace 'workspace)
       (eq :ready (workspace-state workspace))
       (eq workspace (buffer-value buffer 'lsp-workspace))
       (lsp-buffer-attachment-valid-p buffer workspace)))

(defun feature-request-error (workspace buffer message code)
  (when (workspace-response-current-p workspace buffer)
    (jsonrpc-editor-error message code)))

(defun buffer-workspace (buffer &optional (errorp t))
  (let ((workspace (buffer-value buffer 'lsp-workspace)))
    (when (and workspace (eq :disposed (workspace-state workspace)))
      (setf (buffer-value buffer 'lsp-workspace) nil
            (buffer-value buffer 'lsp-state) nil
            (buffer-value buffer 'lsp-opened-uri) nil
            workspace nil))
    (when (and workspace
               (not (lsp-buffer-attachment-valid-p buffer workspace)))
      (setf workspace (rebind-lsp-buffer buffer workspace)))
    (or workspace
        (when (and errorp (buffer-language-id buffer))
          (error "Buffer ~A is not attached to an LSP workspace."
                 (buffer-name buffer))))))

(defun all-workspaces ()
  (loop :for workspace-list :being :each :hash-value
          :in *workspace-list-per-language-id*
        :append (copy-list (workspace-list-workspaces workspace-list))))

(defun shutdown-workspace-client (workspace initialized-p)
  (let ((client (workspace-client workspace)))
    (when initialized-p
      (let ((jsonrpc:*default-timeout* *workspace-shutdown-timeout*))
        (ignore-errors
          (request:request client (make-instance 'lsp:shutdown) nil))
        (ignore-errors
          (request:request client (make-instance 'lsp:exit) nil))
        ;; Notifications are queued by jsonrpc.  Give its writer a bounded
        ;; opportunity to flush `exit` before the transport is torn down.
        (sleep 0.05)))
    (ignore-errors
      (jsonrpc:client-disconnect
       (lem-language-client/client:client-connection client)))
    (ignore-errors (client:dispose client))))

(defun stop-workspace-initialization-timer (workspace)
  (when-let (timer (workspace-initialization-timer workspace))
    (ignore-errors (stop-timer timer))
    (setf (workspace-initialization-timer workspace) nil)))

(defun stop-workspace-startup (workspace)
  (stop-workspace-initialization-timer workspace)
  (when-let (spinner (workspace-startup-spinner workspace))
    (ignore-errors (spinner:stop-loading-spinner spinner))
    (setf (workspace-startup-spinner workspace) nil)))

(defun stop-workspace-progress (workspace)
  (maphash (lambda (token timer)
             (declare (ignore token))
             (ignore-errors (stop-timer timer)))
           (workspace-progress-removal-timers workspace))
  (clrhash (workspace-progress-removal-timers workspace))
  (clrhash (workspace-progress-reports workspace)))

(defun call-lem-yath-lsp-function (name &rest arguments)
  (let* ((package (find-package :lem-yath))
         (symbol (and package (find-symbol name package))))
    (when (and symbol (fboundp symbol))
      (apply symbol arguments))))

(defun dispose-workspace (workspace)
  (unless (member (workspace-state workspace) '(:stopping :disposed))
    (let ((initialized-p (eq :ready (workspace-state workspace))))
      (remove-workspace workspace)
      (setf (workspace-state workspace) :stopping)
      (stop-workspace-startup workspace)
      (stop-workspace-progress workspace)
      (call-lem-yath-lsp-function "LSP-STOP-FILE-WATCHES" workspace)
      (dolist (buffer (copy-list (workspace-buffers workspace)))
        (detach-lsp-buffer buffer workspace :notify initialized-p))
      (setf (workspace-pending-continuations workspace) nil)
      (shutdown-workspace-client workspace initialized-p)
      (setf (workspace-state workspace) :disposed))))

(defun dispose-all-workspaces ()
  (dolist (workspace (copy-list (all-workspaces)))
    (dispose-workspace workspace))
  (clrhash *workspace-table*)
  (clrhash *workspace-list-per-language-id*))

;;;
(defvar *lsp-mode-keymap* (make-keymap))

(define-key *lsp-mode-keymap* "C-c h" 'lsp-hover)

(defun capture-buffer-binding (buffer variable)
  (let* ((unbound (gensym "UNBOUND-"))
         (value (buffer-value buffer variable unbound)))
    (if (eq value unbound)
        (cons nil nil)
        (cons t value))))

(defun restore-buffer-binding (buffer variable binding)
  (if (car binding)
      (setf (buffer-value buffer variable) (cdr binding))
      (buffer-unbound buffer variable)))

(defun editor-variable-buffer-key (symbol)
  (lem/common/var:editor-variable-local-indicator
   (get symbol 'lem/common/var:editor-variable)))

(defun capture-editor-variable-binding (buffer symbol)
  (capture-buffer-binding buffer (editor-variable-buffer-key symbol)))

(defun restore-editor-variable-binding (buffer symbol binding)
  (restore-buffer-binding buffer (editor-variable-buffer-key symbol) binding))

(defun install-lsp-buffer-functions (buffer)
  (when-let (functions (buffer-value buffer 'lsp-mode-previous-functions))
    (unless (eq (first functions) (buffer-major-mode buffer))
      (when (eq (buffer-value buffer 'revert-buffer-function)
                #'lsp-revert-buffer)
        (restore-buffer-binding
         buffer 'revert-buffer-function (fifth functions)))
      (setf (buffer-value buffer 'lsp-mode-previous-functions) nil)))
  (unless (buffer-value buffer 'lsp-mode-previous-functions)
    (setf (buffer-value buffer 'lsp-mode-previous-functions)
          (list
           (buffer-major-mode buffer)
           (capture-editor-variable-binding
            buffer 'language-mode:completion-spec)
           (capture-editor-variable-binding
            buffer 'language-mode:find-definitions-function)
           (capture-editor-variable-binding
            buffer 'language-mode:find-references-function)
           (capture-buffer-binding buffer 'revert-buffer-function))))
  (setf (variable-value 'language-mode:completion-spec :buffer buffer)
        (lem/completion-mode:make-completion-spec
         'text-document/completion
         :async t
         :filter-function #'filter-completion-items)
        (variable-value 'language-mode:find-definitions-function :buffer buffer)
        #'lsp-find-definitions
        (variable-value 'language-mode:find-references-function :buffer buffer)
        #'lsp-find-references
        (buffer-value buffer 'revert-buffer-function)
        #'lsp-revert-buffer))

(defun restore-lsp-buffer-functions (buffer)
  (when-let (functions (buffer-value buffer 'lsp-mode-previous-functions))
    (when (eq (first functions) (buffer-major-mode buffer))
      (restore-editor-variable-binding
       buffer 'language-mode:completion-spec (second functions))
      (restore-editor-variable-binding
       buffer 'language-mode:find-definitions-function (third functions))
      (restore-editor-variable-binding
       buffer 'language-mode:find-references-function (fourth functions)))
    (when (eq (buffer-value buffer 'revert-buffer-function)
              #'lsp-revert-buffer)
      (restore-buffer-binding
       buffer 'revert-buffer-function (fifth functions)))
    (setf (buffer-value buffer 'lsp-mode-previous-functions) nil)))

(defun disable-lsp-mode-for-buffer (buffer)
  (when (and (not (deleted-buffer-p buffer))
             (mode-active-p buffer 'lsp-mode))
    (with-current-buffer buffer
      (lsp-mode nil))))

(define-minor-mode lsp-mode
    (:name "LSP"
     :keymap *lsp-mode-keymap*
     :enable-hook 'enable-hook
     :disable-hook 'disable-hook)
  (let ((buffer (current-buffer)))
    (if (mode-active-p buffer 'lsp-mode)
        (install-lsp-buffer-functions buffer)
        (restore-lsp-buffer-functions buffer))))

(defun lsp-buffer-eligible-p (buffer)
  "Whether BUFFER is a local, file-backed buffer with a registered LSP spec."
  (and (not (buffer-temporary-p buffer))
       (buffer-filename buffer)
       (buffer-language-spec buffer)))

(defun enable-hook ()
  (let ((buffer (current-buffer)))
    (if (not (lsp-buffer-eligible-p buffer))
        (disable-minor-mode 'lsp-mode)
        (handler-case
            (progn
              (add-hook *exit-editor-hook* 'dispose-all-workspaces)
              (ensure-lsp-buffer buffer
                                 :then (lambda ()
                                         (enable-document-highlight-idle-timer))))
          (error (condition)
            (disable-minor-mode 'lsp-mode)
            (show-message (princ-to-string condition)))))))

(defun disable-hook ()
  (close-lsp-buffer (current-buffer)))

(defun reopen-buffer (buffer)
  (text-document/did-close buffer)
  (text-document/did-open buffer))

(define-command lsp-sync-buffer () ()
  (reopen-buffer (current-buffer)))

(defun lsp-revert-buffer (buffer)
  (remove-hook (variable-value 'before-change-functions :buffer buffer) 'handle-change-buffer)
  (unwind-protect (progn
                    (clear-document-highlight-overlays)
                    (sync-buffer-with-file-content buffer)
                    (reopen-buffer buffer))
    (add-hook (variable-value 'before-change-functions :buffer buffer) 'handle-change-buffer)))

(defun convert-to-characters (string-characters)
  (map 'list
       (lambda (string) (char string 0))
       string-characters))

(defun get-completion-trigger-characters (workspace)
  (convert-to-characters
   (handler-case
       (lsp:completion-options-trigger-characters
        (lsp:server-capabilities-completion-provider
         (workspace-server-capabilities workspace)))
     (unbound-slot ()
       nil))))

(defun get-signature-help-trigger-characters (workspace)
  (convert-to-characters
   (handler-case
       (lsp:signature-help-options-trigger-characters
        (lsp:server-capabilities-signature-help-provider
         (workspace-server-capabilities workspace)))
     (unbound-slot ()
       nil))))

(defun self-insert-hook (c)
  (when-let ((workspace (buffer-workspace (current-buffer) nil)))
    (when (workspace-response-current-p workspace (current-buffer))
      (when-let ((command
                   (gethash c (workspace-trigger-characters workspace))))
        (funcall command c)))))

(defun buffer-change-event-to-content-change-event (point arg workspace)
  (labels ((inserting-content-change-event (string)
             (let ((position (point-to-workspace-position point workspace)))
               (make-lsp-map :range (make-instance 'lsp:range
                                                   :start position
                                                   :end position)
                             :range-length 0
                             :text string)))
           (deleting-content-change-event (count)
             (with-point ((end point))
               (character-offset end count)
               (let ((deleted-text (points-to-string point end)))
                 (make-lsp-map :range
                               (make-instance
                                'lsp:range
                                :start (point-to-workspace-position point workspace)
                                :end (point-to-workspace-position end workspace))
                             :range-length
                             (string-index-to-position-character
                              deleted-text
                              (length deleted-text)
                             (workspace-position-encoding workspace))
                             :text "")))))
    (etypecase arg
      (character
       (inserting-content-change-event (string arg)))
      (string
       (inserting-content-change-event arg))
      (integer
       (deleting-content-change-event arg)))))

(defun handle-change-buffer (point arg)
  (let* ((buffer (point-buffer point))
         (workspace (buffer-workspace buffer nil)))
    (when (and workspace (workspace-response-current-p workspace buffer))
      (let ((change-event
              (buffer-change-event-to-content-change-event
               point arg workspace)))
        (text-document/did-change buffer (make-lsp-array change-event))))))

(defun add-buffer-hooks (buffer)
  (add-hook (variable-value 'after-save-hook :buffer buffer) 'handle-save-buffer)
  (add-hook (variable-value 'before-change-functions :buffer buffer) 'handle-change-buffer)
  (add-hook (variable-value 'self-insert-after-hook :buffer buffer) 'self-insert-hook))

(defun remove-buffer-hooks (buffer)
  (remove-hook (variable-value 'after-save-hook :buffer buffer) 'handle-save-buffer)
  (remove-hook (variable-value 'before-change-functions :buffer buffer) 'handle-change-buffer)
  (remove-hook (variable-value 'self-insert-after-hook :buffer buffer) 'self-insert-hook))

(defun queue-workspace-continuation (workspace buffer continuation)
  (when continuation
    (push (cons buffer continuation)
          (workspace-pending-continuations workspace))))

(defun run-workspace-continuations (workspace buffer)
  (let ((entries
          (remove-if-not (lambda (entry) (eq buffer (car entry)))
                         (workspace-pending-continuations workspace))))
    (setf (workspace-pending-continuations workspace)
          (delete buffer
                  (workspace-pending-continuations workspace)
                  :key #'car))
    (dolist (entry (nreverse entries))
      (handler-case (funcall (cdr entry))
        (error (condition)
          (show-message (format nil "LSP continuation failed: ~A" condition)))))))

(defvar *lsp-buffer-attached-hook* '()
  "Functions called with BUFFER and WORKSPACE after ownership is attached.")

(defvar *lsp-buffer-detached-hook* '()
  "Functions called with BUFFER and WORKSPACE after ownership is detached.")

(defun attach-lsp-buffer (buffer workspace)
  (let ((old-workspace (buffer-value buffer 'lsp-workspace)))
    (unless (eq old-workspace workspace)
      (when old-workspace
        (detach-lsp-buffer buffer old-workspace))
      (setf (buffer-value buffer 'lsp-workspace) workspace
            (buffer-value buffer 'lsp-state) :pending)
      (pushnew buffer (workspace-buffers workspace))
      (add-hook (variable-value 'kill-buffer-hook :buffer buffer)
                'close-lsp-buffer)
      (run-hooks *lsp-buffer-attached-hook* buffer workspace)))
  workspace)

(defun activate-lsp-buffer (buffer workspace)
  (when (and (eq :ready (workspace-state workspace))
             (eq workspace (buffer-value buffer 'lsp-workspace))
             (not (deleted-buffer-p buffer))
             (not (eq :open (buffer-value buffer 'lsp-state))))
    (setf (buffer-value buffer 'lsp-state) :open
          (buffer-value buffer 'lsp-opened-uri) (buffer-uri buffer))
    (add-buffer-hooks buffer)
    (text-document/did-open buffer))
  workspace)

(defun detach-lsp-buffer (buffer workspace &key (notify t))
  (when (eq workspace (buffer-value buffer 'lsp-workspace))
    (when (and notify
               (eq :open (buffer-value buffer 'lsp-state)))
      (ignore-errors
        (text-document/did-close
         buffer
         :workspace workspace
         :uri (buffer-opened-uri buffer))))
    (remove-buffer-hooks buffer)
    (reset-buffer-diagnostic buffer)
    (unless (deleted-buffer-p buffer)
      (with-current-buffer buffer
        (clear-document-highlight-overlays)))
    (remove-hook (variable-value 'kill-buffer-hook :buffer buffer)
                 'close-lsp-buffer)
    (setf (buffer-value buffer 'lsp-workspace) nil
          (buffer-value buffer 'lsp-state) nil
          (buffer-value buffer 'lsp-opened-uri) nil)
    (run-hooks *lsp-buffer-detached-hook* buffer workspace))
  (setf (workspace-buffers workspace)
        (delete buffer (workspace-buffers workspace))
        (workspace-pending-continuations workspace)
        (delete buffer
                (workspace-pending-continuations workspace)
                :key #'car))
  (when (and (eq :starting (workspace-state workspace))
             (null (workspace-buffers workspace)))
    (dispose-workspace workspace))
  buffer)

(defun rebind-lsp-buffer (buffer old-workspace &key continuation)
  (detach-lsp-buffer buffer old-workspace)
  (cond
    ((and (mode-active-p buffer 'lsp-mode)
          (lsp-buffer-eligible-p buffer))
     (handler-case
         (ensure-lsp-buffer buffer :then continuation)
       (error (condition)
         (disable-lsp-mode-for-buffer buffer)
         (show-message (princ-to-string condition))
         nil)))
    (t
     (disable-lsp-mode-for-buffer buffer)
     nil)))

(defun close-lsp-buffer (buffer)
  (when-let (workspace (buffer-value buffer 'lsp-workspace))
    (detach-lsp-buffer buffer workspace)))

(defun reassign-language-workspace (workspace)
  (dolist (buffer (copy-list (buffer-list)))
    (when (and (equal (workspace-language-id workspace)
                      (buffer-language-id buffer))
               (buffer-value buffer 'lsp-workspace))
      (let ((old-workspace (buffer-value buffer 'lsp-workspace)))
        (unless (eq old-workspace workspace)
          (detach-lsp-buffer buffer old-workspace)
          (attach-lsp-buffer buffer workspace)
          (activate-lsp-buffer buffer workspace)))))
  workspace)

(defun configuration-item-section (item)
  (handler-case
      (lsp:configuration-item-section item)
    (unbound-slot () nil)))

(defun workspace-configuration-section (workspace section)
  (let ((value (workspace-configuration workspace)))
    (if (or (null section) (zerop (length section)))
        (or value +null+)
        (dolist (name (uiop:split-string section :separator '(#\.)) value)
          (unless (hash-table-p value)
            (return +null+))
          (multiple-value-bind (next present-p) (gethash name value)
            (unless present-p
              (return +null+))
            (setf value next))))))

(defun workspace/configuration (workspace params)
  (let ((params (convert-from-json params 'lsp:configuration-params)))
    (map 'vector
         (lambda (item)
           (workspace-configuration-section
            workspace
            (configuration-item-section item)))
         (lsp:configuration-params-items params))))

(defun client/register-capability (workspace params)
  (call-lem-yath-lsp-function "LSP-REGISTER-CAPABILITIES" workspace params)
  +null+)

(defun client/unregister-capability (workspace params)
  (call-lem-yath-lsp-function "LSP-UNREGISTER-CAPABILITIES" workspace params)
  +null+)

(defun window/work-done-progress-create (params)
  (declare (ignore params))
  +null+)

(defparameter *max-work-done-progress-reports* 64)

(defstruct work-done-progress
  percentage)

(defun work-done-progress-token-p (token)
  (or (stringp token) (integerp token)))

(defun work-done-progress-percentage-value (value)
  (multiple-value-bind (percentage present-p) (gethash "percentage" value)
    (and present-p
         (integerp percentage)
         (<= 0 percentage 100)
         percentage)))

(defun stop-work-done-progress-removal-timer (workspace token)
  (let ((timers (workspace-progress-removal-timers workspace)))
    (when-let (timer (gethash token timers))
      (ignore-errors (stop-timer timer))
      (remhash token timers))))

(defun workspace-progress-begin (workspace token value)
  (let ((reports (workspace-progress-reports workspace)))
    (multiple-value-bind (old-report present-p) (gethash token reports)
      (declare (ignore old-report))
      (when (or present-p
                (< (hash-table-count reports)
                   *max-work-done-progress-reports*))
        (stop-work-done-progress-removal-timer workspace token)
        (setf (gethash token reports)
              (make-work-done-progress
               :percentage (work-done-progress-percentage-value value)))
        (redraw-display)))))

(defun workspace-progress-report (workspace token value)
  (alexandria:when-let
      ((report (gethash token (workspace-progress-reports workspace))))
    (setf (work-done-progress-percentage report)
          (work-done-progress-percentage-value value))
    (redraw-display)))

(defun workspace-progress-end (workspace token)
  (let ((reports (workspace-progress-reports workspace))
        (timers (workspace-progress-removal-timers workspace)))
    (alexandria:when-let ((report (gethash token reports)))
      (setf (work-done-progress-percentage report) 100)
      (stop-work-done-progress-removal-timer workspace token)
      (let (timer)
        (setf timer
              (start-timer
               (make-timer
                (lambda ()
                  (when (eq timer (gethash token timers))
                    (remhash token timers)
                    (remhash token reports)
                    (redraw-display)))
                :name "lsp-work-done-progress-expiry")
               2000)
              (gethash token timers) timer))
      (redraw-display))))

(defun workspace-progress-percentage (workspace)
  (let ((sum 0)
        (count 0))
    (maphash
     (lambda (token report)
       (declare (ignore token))
       (alexandria:when-let
           ((percentage (work-done-progress-percentage report)))
         (incf sum percentage)
         (incf count)))
     (workspace-progress-reports workspace))
    (and (plusp count) (floor sum count))))

(defun $/progress (workspace params)
  (when (hash-table-p params)
    (let ((token (gethash "token" params))
          (value (gethash "value" params)))
      (when (and (work-done-progress-token-p token)
                 (hash-table-p value))
        (let ((kind (gethash "kind" value)))
          (when (stringp kind)
            (send-event
             (lambda ()
               (unless (member (workspace-state workspace)
                               '(:stopping :disposed))
                 (cond
                   ((string= kind "begin")
                    (workspace-progress-begin workspace token value))
                   ((string= kind "report")
                    (workspace-progress-report workspace token value))
                   ((string= kind "end")
                    (workspace-progress-end workspace token)))))))))))
  +null+)

(defun register-lsp-method (workspace method function)
  (jsonrpc:expose (lem-language-client/client:client-connection (workspace-client workspace))
                  method
                  function))

(defun initialize-workspace (workspace continuation &key error)
  (register-lsp-method workspace
                       "textDocument/publishDiagnostics"
                       (lambda (params)
                         (text-document/publish-diagnostics workspace params)))
  (register-lsp-method workspace
                       "window/showMessage"
                       'window/show-message)
  (register-lsp-method workspace
                       "window/logMessage"
                       'window/log-message)
  (register-lsp-method
   workspace
   "workspace/configuration"
   (lambda (params) (workspace/configuration workspace params)))
  (register-lsp-method workspace
                       "client/registerCapability"
                       (lambda (params)
                         (client/register-capability workspace params)))
  (register-lsp-method workspace
                       "client/unregisterCapability"
                       (lambda (params)
                         (client/unregister-capability workspace params)))
  (register-lsp-method workspace
                       "window/workDoneProgress/create"
                       'window/work-done-progress-create)
  (register-lsp-method
   workspace
   "$/progress"
   (lambda (params) ($/progress workspace params)))
  (initialize workspace
              (lambda ()
                (funcall continuation workspace))
              :error error))

(defun connect (client continuation &key error continue-p)
  (bt2:make-thread
   (lambda ()
     (loop :with condition := nil
           :repeat 20
           :when (and continue-p (not (funcall continue-p)))
             :do (return)
           :do (handler-case (with-yason-bindings ()
                               (lem-language-client/client:jsonrpc-connect client))
                 (:no-error (&rest values)
                   (declare (ignore values))
                   (send-event continuation)
                   (return))
                 (error (c)
                   (setq condition c)
                   (sleep 0.5)))
           :finally
             (when (or (null continue-p) (funcall continue-p))
               (send-event
                (lambda ()
                  (let ((message
                          (format nil
                                  "Could not establish a connection with the Language Server (condition: ~A)"
                                  condition)))
                    (if error
                        (funcall error message nil)
                        (editor-error "~A" message))))))))))

(defgeneric initialized-workspace (mode workspace)
  (:method (mode workspace)))

(defun fail-workspace-initialization (workspace spinner message code)
  (declare (ignore spinner code))
  (stop-workspace-startup workspace)
  (unless (member (workspace-state workspace) '(:stopping :disposed))
    (let ((buffers (copy-list (workspace-buffers workspace))))
      (dispose-workspace workspace)
      (dolist (buffer buffers)
        (disable-lsp-mode-for-buffer buffer)))
    (show-message (format nil "LSP initialization failed: ~A" message))
    (redraw-display)))

(defun finish-workspace-initialization (workspace spinner)
  (stop-workspace-startup workspace)
  (if (and (eq :starting (workspace-state workspace))
           (current-workspace-entry-p workspace))
      (handler-case
          (progn
            (initialized workspace)
            (setf (workspace-state workspace) :ready)
            (set-trigger-characters workspace)
            (let ((mode (ensure-mode-object
                         (spec-mode (workspace-spec workspace)))))
              (initialized-workspace mode workspace))
            (dolist (buffer
                     (reverse (copy-list (workspace-buffers workspace))))
              (when (and (not (deleted-buffer-p buffer))
                         (eq workspace (buffer-value buffer 'lsp-workspace)))
                (activate-lsp-buffer buffer workspace)
                (run-workspace-continuations workspace buffer)))
            (redraw-display))
        (error (condition)
          (fail-workspace-initialization
           workspace spinner (princ-to-string condition) nil)))
      (progn
        (dispose-workspace workspace)
        (redraw-display))))

(defun connect-and-initialize (workspace buffer continuation)
  (add-workspace workspace)
  (attach-lsp-buffer buffer workspace)
  (queue-workspace-continuation workspace buffer continuation)
  (let ((spinner (spinner:start-loading-spinner
                  :modeline
                  :loading-message "initializing"
                  :buffer buffer)))
    (setf (workspace-startup-spinner workspace) spinner)
    (labels ((fail (message code)
               (fail-workspace-initialization workspace spinner message code))
             (start-initialize ()
               (setf (workspace-initialization-timer workspace)
                     (start-timer
                      (make-timer
                       (lambda ()
                         (when (and
                                (eq :starting (workspace-state workspace))
                                (current-workspace-entry-p workspace))
                           (fail
                            "Language server initialization timed out."
                            nil)))
                       :name "lsp-initialize-timeout")
                      (* 1000 *workspace-initialize-timeout*)))
               (initialize-workspace
                workspace
                (lambda (workspace)
                  (finish-workspace-initialization workspace spinner))
                :error #'fail)))
      (connect (workspace-client workspace)
               (lambda ()
                 (if (and (eq :starting (workspace-state workspace))
                          (current-workspace-entry-p workspace))
                     (handler-case
                         (start-initialize)
                       (error (condition)
                         (fail (princ-to-string condition) nil)))
                     (progn
                       (spinner:stop-loading-spinner spinner)
                       (dispose-workspace workspace))))
               :error #'fail
               :continue-p
               (lambda ()
                 (eq :starting (workspace-state workspace)))))))

(defun ensure-lsp-buffer (buffer &key ((:then continuation)))
  (unless (lsp-buffer-eligible-p buffer)
    (editor-error "LSP requires a local file-backed buffer with a language spec."))
  (let* ((spec (buffer-language-spec buffer))
         (workspace (find-workspace-for-buffer spec buffer)))
    (when (and workspace
               (eq :ready (workspace-state workspace))
               (not (ignore-errors
                      (client:alive-p (workspace-client workspace)))))
      (let ((old-workspace workspace)
            (buffers (adjoin buffer
                             (remove-if #'deleted-buffer-p
                                        (copy-list
                                         (workspace-buffers workspace))))))
        (dispose-workspace old-workspace)
        (handler-case
            (setf workspace
                  (restart-workspace (workspace-spec old-workspace)
                                     old-workspace
                                     buffers))
          (error (condition)
            (dolist (affected-buffer buffers)
              (disable-lsp-mode-for-buffer affected-buffer))
            (error condition)))
        (queue-workspace-continuation workspace buffer continuation)
        (return-from ensure-lsp-buffer workspace)))
    (cond
      ((and workspace (eq :ready (workspace-state workspace)))
       (attach-lsp-buffer buffer workspace)
       (activate-lsp-buffer buffer workspace)
       (when continuation (funcall continuation))
       workspace)
      ((and workspace (eq :starting (workspace-state workspace)))
       (attach-lsp-buffer buffer workspace)
       (queue-workspace-continuation workspace buffer continuation)
       workspace)
      (t
       (let* ((workspace (make-workspace :spec spec :buffer buffer))
              (client (run-server
                       spec :directory (workspace-root-pathname workspace))))
         (setf (workspace-client workspace) client)
         (connect-and-initialize workspace buffer continuation)
         workspace)))))

(defgeneric prepare-restarted-workspace (spec old-workspace new-workspace)
  (:method (spec old-workspace new-workspace)
    (declare (ignore spec old-workspace))
    new-workspace))

(defgeneric restart-workspace (spec workspace buffers)
  (:method (spec workspace buffers)
    (let* ((buffer (first buffers))
           (new-workspace (make-workspace :spec spec :buffer buffer)))
      (prepare-restarted-workspace spec workspace new-workspace)
      (setf (workspace-client new-workspace)
            (run-server spec
                        :directory
                        (workspace-root-pathname new-workspace)))
      (connect-and-initialize new-workspace buffer nil)
      (dolist (other-buffer (rest buffers))
        (attach-lsp-buffer other-buffer new-workspace))
      new-workspace)))

(defun check-connection ()
  (let ((workspace (buffer-workspace (current-buffer) nil)))
    (unless (and workspace (eq :ready (workspace-state workspace)))
      (editor-error "No initialized LSP workspace for this buffer."))
    workspace))

(defun buffer-to-text-document-item (buffer)
  (make-instance 'lsp:text-document-item
                 :uri (buffer-uri buffer)
                 :language-id (buffer-language-id buffer)
                 :version (buffer-version buffer)
                 :text (buffer-text buffer)))

(defun make-text-document-identifier (buffer)
  (make-instance 'lsp:text-document-identifier
                 :uri (buffer-uri buffer)))

(defun workspace-position-encoding (workspace)
  (let ((encoding
          (and workspace
               (handler-case
                   (lsp:server-capabilities-position-encoding
                    (workspace-server-capabilities workspace))
                 (unbound-slot () nil)))))
    (if (and (stringp encoding)
             (member encoding
                     (list lsp:position-encoding-kind-utf8
                           lsp:position-encoding-kind-utf16
                           lsp:position-encoding-kind-utf32)
                     :test #'string=))
        encoding
        lsp:position-encoding-kind-utf16)))

(defun character-position-width (character encoding)
  (cond
    ((string= encoding lsp:position-encoding-kind-utf8)
     (babel:string-size-in-octets (string character) :encoding :utf-8))
    ((string= encoding lsp:position-encoding-kind-utf16)
     (if (> (char-code character) #xffff) 2 1))
    (t
     1)))

(defun string-index-to-position-character (string index encoding)
  (loop :for offset :below index
        :sum (character-position-width (char string offset) encoding)))

(defun position-character-to-string-index (string character encoding)
  "Convert protocol code units to a character index, rejecting split units."
  (when (and (integerp character) (not (minusp character)))
    (loop :with units := 0
          :for index :from 0
          :when (= units character)
            :return index
          :when (= index (length string))
            :return nil
          :do (incf units
                    (character-position-width (char string index) encoding))
          :when (> units character)
            :return nil)))

(defun point-to-workspace-position (point workspace)
  (let ((encoding (workspace-position-encoding workspace)))
    (make-instance
     'lsp:position
     :line (point-lsp-line-number point)
     :character
     (string-index-to-position-character
      (line-string point) (point-charpos point) encoding))))

(defun points-to-workspace-range (start end workspace)
  (make-instance 'lsp:range
                 :start (point-to-workspace-position start workspace)
                 :end (point-to-workspace-position end workspace)))

(defun move-to-workspace-position (point position workspace)
  "Move POINT to POSITION using the workspace-negotiated code-unit encoding."
  (let ((line (lsp:position-line position))
        (character (lsp:position-character position)))
    (when (and (integerp line)
               (not (minusp line))
               (move-to-line point (1+ line)))
      (alexandria:when-let
          ((index
             (position-character-to-string-index
              (line-string point)
              character
              (workspace-position-encoding workspace))))
        (line-start point)
        (character-offset point index)
        point))))

(defun make-text-document-position-arguments (point workspace)
  (list :text-document (make-text-document-identifier (point-buffer point))
        :position (point-to-workspace-position point workspace)))

(defun find-buffer-from-uri (uri)
  (find uri (buffer-list) :key #'buffer-uri :test #'equal))

(defun get-buffer-from-text-document-identifier (text-document-identifier)
  (let ((uri (lsp:text-document-identifier-uri text-document-identifier)))
    (find-buffer-from-uri uri)))

(defun edit-ranges-overlap-p (start1 end1 start2 end2)
  "Return true when two half-open edit ranges cannot be applied independently."
  (let ((empty1 (point= start1 end1))
        (empty2 (point= start2 end2)))
    (cond
      ((and empty1 empty2)
       (point= start1 start2))
      (empty1
       (and (point<= start2 start1) (point< start1 end2)))
      (empty2
       (and (point<= start1 start2) (point< start2 end1)))
      (t
       (and (point< start1 end2) (point< start2 end1))))))

(defun ensure-edit-range-writable (start end)
  (let ((buffer (point-buffer start)))
    (lem/buffer/internal::check-read-only-buffer buffer)
    (lem/buffer/internal::check-read-only-at-point start 0)
    (when (point< start end)
      (lem/buffer/internal::check-read-only-at-point
       start (count-characters start end)))))

(defun apply-text-edits (buffer text-edits workspace)
  (when (or (null text-edits) (lsp-null-p text-edits))
    (return-from apply-text-edits nil))
  (labels ((delete-edit-points (edits)
             (dolist (edit edits)
               (delete-point (first edit))
               (delete-point (second edit))))
           (ranges-valid-p (edits)
             (loop :for rest :on edits
                   :for edit := (first rest)
                   :never
                   (some (lambda (other)
                           (edit-ranges-overlap-p
                            (first edit) (second edit)
                            (first other) (second other)))
                         (rest rest))))
           (prepare-edits ()
             (let ((edits '()))
               (handler-case
                   (progn
                     (do-sequence (text-edit text-edits)
                       (let ((range (lsp:text-edit-range text-edit))
                             (new-text (lsp:text-edit-new-text text-edit)))
                         (with-point ((start (buffer-point buffer))
                                      (end (buffer-point buffer)))
                           (unless (and
                                    (stringp new-text)
                                    (move-to-workspace-position
                                     start (lsp:range-start range) workspace)
                                    (move-to-workspace-position
                                     end (lsp:range-end range) workspace)
                                    (point<= start end))
                             (error "Invalid LSP text edit"))
                           (push (list (copy-point start :left-inserting)
                                       (copy-point end :right-inserting)
                                       new-text)
                                 edits))))
                     (setf edits (nreverse edits))
                     (unless (ranges-valid-p edits)
                       (error "Overlapping LSP text edits"))
                     edits)
                 (error (condition)
                   (delete-edit-points edits)
                   (error condition))))))
    (let ((edits (prepare-edits)))
      (unwind-protect
           (progn
             (dolist (edit edits)
               (ensure-edit-range-writable (first edit) (second edit)))
             (dolist (edit (sort (copy-list edits) #'point> :key #'first))
               (delete-between-points (first edit) (second edit))
               (insert-string (first edit) (third edit))))
        (delete-edit-points edits)))))

(defgeneric apply-document-change (workspace document-change))

(defmethod apply-document-change (workspace (document-change lsp:text-document-edit))
  (let* ((buffer
           (get-buffer-from-text-document-identifier
            (lsp:text-document-edit-text-document document-change))))
    (apply-text-edits
     buffer (lsp:text-document-edit-edits document-change) workspace)))

(defmethod apply-document-change (workspace (document-change lsp:create-file))
  (declare (ignore workspace))
  (error "createFile is not yet supported"))

(defmethod apply-document-change (workspace (document-change lsp:rename-file))
  (declare (ignore workspace))
  (error "renameFile is not yet supported"))

(defmethod apply-document-change (workspace (document-change lsp:delete-file))
  (declare (ignore workspace))
  (error "deleteFile is not yet supported"))

(defun apply-change (workspace uri text-edits)
  (let ((buffer (find-buffer-from-uri uri)))
    (apply-text-edits buffer text-edits workspace)))

(defun apply-workspace-edit (workspace workspace-edit)
  (labels ((apply-document-changes (document-changes)
             (do-sequence (document-change document-changes)
               (apply-document-change workspace document-change)))
           (apply-changes (changes)
             (maphash (lambda (uri text-edits)
                        (apply-change workspace uri text-edits))
                      changes)))
    (if-let ((document-changes (handler-case
                                   (lsp:workspace-edit-document-changes workspace-edit)
                                 (unbound-slot () nil))))
      (apply-document-changes document-changes)
      (when-let ((changes (handler-case (lsp:workspace-edit-changes workspace-edit)
                            (unbound-slot () nil))))
        (apply-changes changes)))))

;;; General Messages

(defgeneric spec-initialization-options (spec)
  (:method (spec) nil))

(defgeneric spec-workspace-configuration (spec)
  (:method (spec) nil))

(defparameter *client-capabilities-text*
  (load-time-value
   (uiop:read-file-string
    (asdf:system-relative-pathname :lem-lsp-mode
                                   "client-capabilities.json"))))

(defun completion-snippet-preparation-function ()
  (variable-value
   'completion:completion-snippet-preparation-function
   :global))

(defun client-capabilities ()
  (let* ((capabilities
           (convert-from-json
            (parse-json *client-capabilities-text*)
            'lsp:client-capabilities))
         (text-document
           (lsp:client-capabilities-text-document capabilities))
         (completion
           (lsp:text-document-client-capabilities-completion text-document))
         (completion-item
           (lsp:completion-client-capabilities-completion-item completion)))
    (setf (gethash "snippetSupport" completion-item)
          (not (null (completion-snippet-preparation-function)))
          (gethash "insertReplaceSupport" completion-item)
          t
          (gethash "resolveSupport" completion-item)
          (make-lsp-map :properties (vector "additionalTextEdits")))
    capabilities))

(defun initialize (workspace continuation &key error)
  (async-request
   (workspace-client workspace)
   (make-instance 'lsp:initialize)
   (apply #'make-instance
          'lsp:initialize-params
          :process-id (get-pid)
          :client-info (make-lsp-map :name "lem" #|:version "0.0.0"|#)
          :root-uri (workspace-root-uri workspace)
          :capabilities (client-capabilities)
          :trace "off"
          :workspace-folders +null+
          (when-let ((value (workspace-initialization-options workspace)))
            (list :initialization-options value)))
   :then (lambda (initialize-result)
           (setf (workspace-server-capabilities workspace)
                 (lsp:initialize-result-capabilities initialize-result))
           (handler-case (lsp:initialize-result-server-info initialize-result)
             (unbound-slot () nil)
             (:no-error (server-info)
               (setf (workspace-server-info workspace)
                     server-info)))
           (funcall continuation))
   :error error))

(defun initialized (workspace)
  (request:request (workspace-client workspace)
                   (make-instance 'lsp:initialized)
                   (make-instance 'lsp:initialized-params)))

;;; Window

;; TODO
;; - window/showMessageRequest
;; - window/workDoneProgress/create
;; - window/workDoenProgress/cancel

(defun window/show-message (params)
  (request::do-request-log "window/showMessage" params :from :server)
  (let* ((params (convert-from-json params 'lsp:show-message-params))
         (text (format nil "~A: ~A"
                       (switch ((lsp:show-message-params-type params) :test #'=)
                         (lsp:message-type-error
                          "Error")
                         (lsp:message-type-warning
                          "Warning")
                         (lsp:message-type-info
                          "Info")
                         (lsp:message-type-log
                          "Log"))
                       (lsp:show-message-params-message params))))
    (send-event (lambda ()
                  (display-popup-message text
                                         :style '(:gravity :top)
                                         :timeout 3)))))

(defun log-message (text)
  (let ((buffer (make-buffer "*lsp output*")))
    (with-point ((point (buffer-point buffer) :left-inserting))
      (buffer-end point)
      (unless (start-line-p point)
        (insert-character point #\newline))
      (insert-string point text))
    (when (get-buffer-windows buffer)
      (redraw-display))))

(defun window/log-message (params)
  (request::do-request-log "window/logMessage" params :from :server)
  (let* ((params (convert-from-json params 'lsp:log-message-params))
         (text (lsp:log-message-params-message params)))
    (send-event (lambda ()
                  (log-message text)))))

;;; Text Synchronization

(defun text-document/did-open (buffer)
  (when-let (workspace (buffer-workspace buffer nil))
    (request:request
     (workspace-client workspace)
     (make-instance 'lsp:text-document/did-open)
     (make-instance 'lsp:did-open-text-document-params
                    :text-document (buffer-to-text-document-item buffer)))))

(defun text-document/did-change (buffer content-changes)
  (when-let (workspace (buffer-workspace buffer nil))
    (request:request
     (workspace-client workspace)
     (make-instance
      'lsp:text-document/did-change)
     (make-instance 'lsp:did-change-text-document-params
                    :text-document (make-instance 'lsp:versioned-text-document-identifier
                                                  :version (buffer-version buffer)
                                                  :uri (buffer-opened-uri buffer))
                    :content-changes content-changes))))

(defun provide-did-save-text-document-p (workspace)
  (let ((sync (lsp:server-capabilities-text-document-sync
               (workspace-server-capabilities workspace))))
    (etypecase sync
      (number
       (member sync
               (list lsp:text-document-sync-kind-full
                     lsp:text-document-sync-kind-incremental)))
      (lsp:text-document-sync-options
       (handler-case (lsp:text-document-sync-options-save sync)
         (unbound-slot ()
           nil))))))

(defun text-document/did-save (buffer)
  (when-let (workspace (buffer-workspace buffer nil))
    (when (provide-did-save-text-document-p workspace)
      (request:request
       (workspace-client workspace)
       (make-instance 'lsp:text-document/did-save)
       (make-instance 'lsp:did-save-text-document-params
                      :text-document (make-text-document-identifier buffer)
                      :text (buffer-text buffer))))))

(defun handle-save-buffer (buffer)
  (when-let (workspace (buffer-value buffer 'lsp-workspace))
    (cond
      ((not (lsp-buffer-attachment-valid-p buffer workspace))
       (rebind-lsp-buffer
        buffer workspace
        :continuation (lambda () (text-document/did-save buffer))))
      ((eq :open (buffer-value buffer 'lsp-state))
       (text-document/did-save buffer)))))

(defun text-document/did-close (buffer &key workspace uri)
  (when-let (workspace (or workspace (buffer-workspace buffer nil)))
    (request:request
     (workspace-client workspace)
     (make-instance 'lsp:text-document/did-close)
     (make-instance 'lsp:did-close-text-document-params
                    :text-document
                    (make-instance 'lsp:text-document-identifier
                                   :uri (or uri
                                            (buffer-opened-uri buffer)
                                            (buffer-uri buffer)))))))

;;; publishDiagnostics

;; TODO
;; - tagSupport
;; - versionSupport

(define-attribute diagnostic-error-attribute
  (t :foreground :base08 :underline t))

(define-attribute diagnostic-warning-attribute
  (t :foreground :base09 :underline t))

(define-attribute diagnostic-information-attribute
  (t :foreground :base04 :underline t))

(define-attribute diagnostic-hint-attribute
  (t :foreground :base0A :underline t))

(defun diagnostic-severity-attribute (diagnostic-severity)
  (switch (diagnostic-severity :test #'=)
    (lsp:diagnostic-severity-error
     'diagnostic-error-attribute)
    (lsp:diagnostic-severity-warning
     'diagnostic-warning-attribute)
    (lsp:diagnostic-severity-information
     'diagnostic-information-attribute)
    (lsp:diagnostic-severity-hint
     'diagnostic-hint-attribute)))

(defstruct diagnostic
  buffer
  position
  message)

(defun buffer-diagnostic-overlays (buffer)
  (buffer-value buffer 'diagnostic-overlays))

(defun (setf buffer-diagnostic-overlays) (overlays buffer)
  (setf (buffer-value buffer 'diagnostic-overlays) overlays))

(defun clear-diagnostic-overlays (buffer)
  (mapc #'delete-overlay (buffer-diagnostic-overlays buffer))
  (setf (buffer-diagnostic-overlays buffer) '()))

(defun buffer-diagnostic-idle-timer (buffer)
  (buffer-value buffer 'diagnostic-idle-timer))

(defun (setf buffer-diagnostic-idle-timer) (idle-timer buffer)
  (setf (buffer-value buffer 'diagnostic-idle-timer) idle-timer))

(defun overlay-diagnostic (overlay)
  (overlay-get overlay 'diagnostic))

(defun buffer-diagnostics (buffer)
  (mapcar #'overlay-diagnostic (buffer-diagnostic-overlays buffer)))

(defun reset-buffer-diagnostic (buffer)
  (clear-diagnostic-overlays buffer)
  (when-let (timer (buffer-diagnostic-idle-timer buffer))
    (stop-timer timer)
    (setf (buffer-diagnostic-idle-timer buffer) nil)))

(defun point-to-xref-position (point)
  (language-mode::make-xref-position :line-number (line-number-at-point point)
                                     :charpos (point-charpos point)))

(defun highlight-diagnostic (workspace buffer diagnostic)
  (with-point ((start (buffer-point buffer))
               (end (buffer-point buffer)))
    (let ((range (lsp:diagnostic-range diagnostic)))
      (unless (and
               (move-to-workspace-position
                start (lsp:range-start range) workspace)
               (move-to-workspace-position
                end (lsp:range-end range) workspace)
               (point<= start end))
        (return-from highlight-diagnostic nil))
      (when (point= start end)
        ;; XXX: for `gopls`
        ;; ```
        ;; func main() {
        ;;     fmt.
        ;; ```
        ;; `range.start` and `range.end` point to the end of the line, and aren't highlighted.
        ;; Shift by one character to fix this.
        (if (end-line-p end)
            (character-offset start -1)
            (character-offset end 1)))
      (let ((overlay (make-overlay start end
                                   (handler-case (lsp:diagnostic-severity diagnostic)
                                     (unbound-slot ()
                                       'diagnostic-error-attribute)
                                     (:no-error (severity)
                                       (diagnostic-severity-attribute severity)))
                                   :end-point-kind :right-inserting)))
        (overlay-put overlay
                     'diagnostic
                     (make-diagnostic :buffer buffer
                                      :position (point-to-xref-position start)
                                      :message (lsp:diagnostic-message diagnostic)))
        (push overlay (buffer-diagnostic-overlays buffer))))))

(defun highlight-diagnostics (workspace params)
  (when-let ((buffer (find-buffer-from-uri (lsp:publish-diagnostics-params-uri params))))
    (when (workspace-response-current-p workspace buffer)
      (reset-buffer-diagnostic buffer)
      (do-sequence (diagnostic (lsp:publish-diagnostics-params-diagnostics params))
        (highlight-diagnostic workspace buffer diagnostic))
      (setf (buffer-diagnostic-idle-timer buffer)
            (start-timer
             (make-idle-timer 'popup-diagnostic :name "lsp-diagnostic")
             200
             :repeat t)))))

(defun popup-diagnostic ()
  (dolist (overlay (buffer-diagnostic-overlays (current-buffer)))
    (when (point<= (overlay-start overlay)
                   (current-point)
                   (overlay-end overlay))
      (unless (mode-active-p (current-buffer) 'lem/completion-mode:completion-mode)
        (display-message (diagnostic-message (overlay-diagnostic overlay))))
      (return))))

(defun text-document/publish-diagnostics (workspace params)
  (request::do-request-log "textDocument/publishDiagnostics" params :from :server)
  (let ((params (convert-from-json params 'lsp:publish-diagnostics-params)))
    (send-event (lambda ()
                  (highlight-diagnostics workspace params)))))

(define-command lsp-document-diagnostics () ()
  (when-let ((diagnostics (buffer-diagnostics (current-buffer))))
    (lem/peek-source:with-collecting-sources (collector)
      (dolist (diagnostic diagnostics)
        (lem/peek-source:with-appending-source
            (point :move-function (let ((diagnostic diagnostic))
                                    (lambda ()
                                      (language-mode:move-to-xref-location-position
                                       (buffer-point (diagnostic-buffer diagnostic))
                                       (diagnostic-position diagnostic)))))
          (insert-string point (buffer-filename (diagnostic-buffer diagnostic))
                         :attribute 'lem/peek-source:filename-attribute)
          (insert-string point ":")
          (insert-string point
                         (princ-to-string (language-mode::xref-position-line-number
                                           (diagnostic-position diagnostic)))
                         :attribute 'lem/peek-source:position-attribute)
          (insert-string point ":")
          (insert-string point
                         (princ-to-string (language-mode::xref-position-charpos
                                           (diagnostic-position diagnostic)))
                         :attribute 'lem/peek-source:position-attribute)
          (insert-string point ":")
          (insert-string point (diagnostic-message diagnostic)))))))

;;; hover

;; TODO
;; - workDoneProgress
;; - partialResult
;; - Set `contentFormat`  `hoverClientCapabilities`
;; - Use `hover`'s `range` to add background color to the range
;; - Check if supported by server

(defun contents-to-string (contents)
  (flet ((marked-string-to-string (marked-string)
           (if (stringp marked-string)
               marked-string
               (or (get-map marked-string "value")
                   ""))))
    (cond
      ;; MarkedString
      ((typep contents 'lsp:marked-string)
       (marked-string-to-string contents))
      ;; MarkedString[]
      ((lsp-array-p contents)
       (with-output-to-string (out)
         (do-sequence (content contents)
           (write-string (marked-string-to-string content)
                         out))))
      ;; MarkupContent
      ((typep contents 'lsp:markup-content)
       (lsp:markup-content-value contents))
      (t
       ""))))

(defun contents-to-markdown-buffer (contents)
  (let ((string (contents-to-string contents)))
    (unless (emptyp (string-trim '(#\space #\newline) string))
      (lem/markdown-buffer:markdown-buffer string))))

(defun provide-hover-p (workspace)
  (handler-case (lsp:server-capabilities-hover-provider
                 (workspace-server-capabilities workspace))
    (unbound-slot () nil)))

(defun text-document/hover (point)
  (when-let ((workspace (get-workspace-from-point point)))
    (when (provide-hover-p workspace)
      (let ((result
              (request:request
               (workspace-client workspace)
               (make-instance 'lsp:text-document/hover)
               (apply #'make-instance
                      'lsp:hover-params
                      (make-text-document-position-arguments point workspace)))))
        (unless (lsp-null-p result)
          (contents-to-markdown-buffer (lsp:hover-contents result)))))))

(define-command lsp-hover () ()
  (check-connection)
  (when-let ((result (text-document/hover (current-point))))
    (display-message result)))

;;; completion

;; TODO
;; - Check if supported by the server
;; - workDoneProgress
;; - partialResult
;; - completionParams.context, include information about how completion was triggered.
;; - There are many unused fields in `completionItem`

(defparameter *completion-resolve-timeout* 2
  "Maximum seconds to block while resolving an accepted completion item.")

(defclass completion-item (completion:completion-item)
  ((sort-text
    :initarg :sort-text
    :reader completion-item-sort-text)))

(defstruct completion-text-edit
  start
  end
  text)

(defstruct completion-document-snapshot
  text
  encoding
  main-start-offset
  main-end-offset)

(defun convert-to-range (point range &optional workspace)
  (let ((range-start (lsp:range-start range))
        (range-end (lsp:range-end range)))
    (with-point ((start point)
                 (end point))
      (unless (and (move-to-workspace-position start range-start workspace)
                   (move-to-workspace-position end range-end workspace)
                   (same-line-p start end)
                   (point<= start point end))
        (error "Invalid LSP completion range"))
      (list start end))))

(defun convert-insert-replace-range (point edit workspace)
  (let ((insert
          (convert-to-range
           point (lsp:insert-replace-edit-insert edit) workspace))
        (replace
          (convert-to-range
           point (lsp:insert-replace-edit-replace edit) workspace)))
    (destructuring-bind (insert-start insert-end) insert
      (destructuring-bind (replace-start replace-end) replace
        (unless (and (point= insert-start replace-start)
                     (point<= insert-end replace-end))
          (error "Invalid LSP InsertReplaceEdit ranges"))))
    replace))

(defun optional-completion-item-value (reader item)
  (handler-case (funcall reader item)
    (unbound-slot () nil)))

(defun completion-item-nonempty-string (reader item fallback)
  (let ((value (optional-completion-item-value reader item)))
    (if (and (stringp value) (plusp (length value)))
        value
        fallback)))

(defun completion-item-value (reader item)
  "Return ITEM's optional value and whether the protocol property was present."
  (handler-case (values (funcall reader item) t)
    (unbound-slot () (values nil nil))))

(defun completion-snippet-p (item)
  (eql (optional-completion-item-value
        #'lsp:completion-item-insert-text-format item)
       lsp:insert-text-format-snippet))

(defun completion-resolve-provider-p (workspace)
  (when workspace
    (alexandria:when-let ((options (provide-completion-p workspace)))
      (handler-case
          (not (null (lsp:completion-options-resolve-provider options)))
        (unbound-slot () nil)))))

(defun completion-item-needs-final-insertion-p (item workspace)
  (or (completion-snippet-p item)
      (nth-value 1
                 (completion-item-value
                  #'lsp:completion-item-additional-text-edits item))
      (completion-resolve-provider-p workspace)))

(defun cancel-completion-resolve-request (client request)
  "Forget REQUEST's callback and ask the server to cancel its work."
  (when request
    (handler-case
        (let* ((id (jsonrpc:request-id request))
               (jsonrpc-client
                 (lem-language-client/client:client-connection client))
               (connection
                 (jsonrpc::transport-connection
                  (jsonrpc::jsonrpc-transport jsonrpc-client))))
          (jsonrpc/connection:remove-callback-for-id connection id)
          (request:request
           client
           (make-instance 'lsp:/cancel-request)
           (make-instance 'lsp:cancel-params :id id)))
      (error (condition)
        (log:warn "Could not cancel timed-out completion resolve: ~A"
                  condition)))))

(defun request-completion-item-resolve (workspace item)
  "Resolve ITEM synchronously with bounded, explicitly cancellable waiting."
  (let ((channel (make-instance 'chanl:unbounded-channel))
        (client (workspace-client workspace))
        (request nil))
    (setf request
          (request:request-async
           client
           (make-instance 'lsp:completion-item/resolve)
           item
           (lambda (response)
             (chanl:send channel (list :success response)))
           (lambda (message code)
             (chanl:send channel (list :error message code)))))
    (handler-case
        (bt2:with-timeout (*completion-resolve-timeout*)
          (destructuring-bind (status value &optional code)
              (chanl:recv channel)
            (ecase status
              (:success value)
              (:error
               (error "Completion resolve failed: ~A (code ~A)"
                      value code)))))
      (bt2:timeout ()
        (cancel-completion-resolve-request client request)
        (error "Completion resolve timed out after ~A seconds"
               *completion-resolve-timeout*)))))

(defun resolve-completion-additional-text-edits (item workspace)
  "Resolve ITEM when supported, importing only lazy additional text edits.

Insertion fields are deliberately retained from the original completion item,
as required by LSP.  A failed or partial resolve falls back to ITEM's original
additional edits."
  (flet ((original-edits ()
           (optional-completion-item-value
            #'lsp:completion-item-additional-text-edits item)))
    (if (not (completion-resolve-provider-p workspace))
        (original-edits)
        (handler-case
            (let ((resolved
                    (request-completion-item-resolve workspace item)))
              (if (typep resolved 'lsp:completion-item)
                  (multiple-value-bind (edits present-p)
                      (completion-item-value
                       #'lsp:completion-item-additional-text-edits resolved)
                    (if present-p edits (original-edits)))
                  (original-edits)))
          (error (condition)
            (message "LSP completion resolve failed: ~A" condition)
            (original-edits))))))

(defun string-line-bounds (string target-line)
  (when (and (integerp target-line) (not (minusp target-line)))
    (loop :with start := 0
          :for line :from 0
          :for newline := (position #\newline string :start start)
          :when (= line target-line)
            :return (values start (or newline (length string)) t)
          :when (null newline)
            :return (values nil nil nil)
          :do (setf start (1+ newline)))))

(defun snapshot-position-offset (snapshot position)
  (multiple-value-bind (line-start line-end found-p)
      (string-line-bounds
       (completion-document-snapshot-text snapshot)
       (lsp:position-line position))
    (when found-p
      (alexandria:when-let
          ((index
             (position-character-to-string-index
              (subseq (completion-document-snapshot-text snapshot)
                      line-start line-end)
              (lsp:position-character position)
              (completion-document-snapshot-encoding snapshot))))
        (+ line-start index)))))

(defun snapshot-offset-to-current-offset
    (snapshot main-start main-end offset)
  "Map an original offset through edits confined to the tracked main range."
  (let ((original-start
          (completion-document-snapshot-main-start-offset snapshot))
        (original-end
          (completion-document-snapshot-main-end-offset snapshot))
        (current-start (1- (position-at-point main-start)))
        (current-end (1- (position-at-point main-end))))
    (cond
      ((< offset original-start)
       (+ offset (- current-start original-start)))
      ((> offset original-end)
       (+ offset (- current-end original-end)))
      ((= offset original-end)
       current-end)
      ((= offset original-start)
       current-start)
      (t
       nil))))

(defun strict-lsp-position-point
    (buffer position kind snapshot main-start main-end)
  "Track POSITION from the response snapshot through completion input edits."
  (alexandria:when-let*
      ((snapshot-offset (snapshot-position-offset snapshot position))
       (current-offset
         (snapshot-offset-to-current-offset
          snapshot main-start main-end snapshot-offset)))
    (with-point ((point (buffer-start-point buffer)))
      (when (move-to-position point (1+ current-offset))
        (copy-point point kind)))))

(defun make-completion-text-edit-from-lsp
    (buffer text-edit snapshot main-start main-end)
  (let ((start nil)
        (end nil))
    (handler-case
        (let* ((range (lsp:text-edit-range text-edit))
               (text (lsp:text-edit-new-text text-edit)))
          (setf start
                (strict-lsp-position-point
                 buffer (lsp:range-start range) :left-inserting
                 snapshot main-start main-end)
                end
                (strict-lsp-position-point
                 buffer (lsp:range-end range) :right-inserting
                 snapshot main-start main-end))
          (if (and start end (stringp text) (point<= start end))
              (values (make-completion-text-edit
                       :start start :end end :text text)
                      t)
              (progn
                (when start (delete-point start))
                (when end (delete-point end))
                (values nil nil))))
      (error ()
        (when start (delete-point start))
        (when end (delete-point end))
        (values nil nil)))))

(defun delete-completion-text-edit-points (edits)
  (dolist (edit edits)
    (delete-point (completion-text-edit-start edit))
    (delete-point (completion-text-edit-end edit))))

(defun completion-text-edit-overlaps-points-p (edit start end)
  (edit-ranges-overlap-p
   (completion-text-edit-start edit)
   (completion-text-edit-end edit)
   start
   end))

(defun completion-text-edits-valid-p (edits main-start main-end)
  (and (point<= main-start main-end)
       (loop :for rest :on edits
             :for edit := (first rest)
             :never (or (completion-text-edit-overlaps-points-p
                         edit main-start main-end)
                        (some (lambda (other)
                                (completion-text-edit-overlaps-points-p
                                 edit
                                 (completion-text-edit-start other)
                                 (completion-text-edit-end other)))
                              (rest rest))))))

(defun prepare-completion-text-edits
    (buffer text-edits main-start main-end snapshot)
  "Precompute and validate all additional edits against one buffer snapshot."
  (if (or (null text-edits) (lsp-null-p text-edits))
      (values nil t)
      (let ((edits '())
            (valid-p t))
        (handler-case
            (do-sequence (text-edit text-edits)
              (when valid-p
                (multiple-value-bind (edit edit-valid-p)
                    (make-completion-text-edit-from-lsp
                     buffer text-edit snapshot main-start main-end)
                  (if edit-valid-p
                      (push edit edits)
                      (setf valid-p nil)))))
          (error ()
            (setf valid-p nil)))
        (setf edits (nreverse edits))
        (unless (and valid-p
                     (completion-text-edits-valid-p
                      edits main-start main-end))
          (delete-completion-text-edit-points edits)
          (setf edits nil
                valid-p nil))
        (values edits valid-p))))

(defun apply-completion-text-edits (edits)
  (dolist (edit (sort (copy-list edits)
                      #'point>
                      :key #'completion-text-edit-start))
    (delete-between-points (completion-text-edit-start edit)
                           (completion-text-edit-end edit))
    (insert-string (completion-text-edit-start edit)
                   (completion-text-edit-text edit))))

(defun ensure-completion-edits-writable (edits main-start main-end)
  "Preflight every disjoint mutation before applying the first one."
  (ensure-edit-range-writable main-start main-end)
  (dolist (edit edits)
    (ensure-edit-range-writable
     (completion-text-edit-start edit)
     (completion-text-edit-end edit))))

(defun prepare-completion-snippet (text label buffer)
  (alexandria:if-let ((function
                       (completion-snippet-preparation-function)))
    (handler-case (funcall function text label buffer)
      (error (condition)
        (message "Cannot prepare LSP snippet: ~A" condition)
        nil))
    (progn
      (message "Cannot expand LSP snippet: no snippet expander is configured")
      nil)))

(defun rollback-completion-change-group (group buffer point-position)
  "Cancel GROUP, failing closed if its retained history cannot be replayed."
  (when (buffer-change-group-active-p group)
    (handler-case
        (progn
          (buffer-cancel-change-group group)
          (unless (move-to-position (buffer-point buffer) point-position)
            (message "Could not restore point after failed LSP completion"))
          nil)
      (error (condition)
        (when (buffer-change-group-active-p group)
          (ignore-errors (buffer-abort-change-group group)))
        condition))))

(defun call-with-completion-change-group (buffer function)
  "Call FUNCTION as one undo-honest completion mutation in BUFFER."
  (let ((group
          (handler-case (buffer-prepare-change-group buffer)
            (error (condition)
              (message "Cannot apply LSP completion transactionally: ~A"
                       condition)
              nil))))
    (unless group
      (return-from call-with-completion-change-group nil))
    (let* ((point-position (position-at-point (buffer-point buffer)))
           (result
            (handler-case (funcall function)
              (error (condition)
                (alexandria:when-let
                    ((rollback-error
                       (rollback-completion-change-group
                        group buffer point-position)))
                  (message "Could not roll back failed LSP completion: ~A"
                           rollback-error))
                (error condition)))))
      (if result
          (handler-case
              (buffer-accept-change-group group)
            (error (condition)
              (alexandria:when-let
                  ((rollback-error
                     (rollback-completion-change-group
                      group buffer point-position)))
                (message "Could not roll back uncommitted LSP completion: ~A"
                         rollback-error))
              (error condition)))
          (alexandria:when-let
              ((rollback-error
                 (rollback-completion-change-group
                  group buffer point-position)))
            (error rollback-error)))
      result)))

(defun completion-final-insert-action (item workspace text label snapshot)
  (when (completion-item-needs-final-insertion-p item workspace)
    (let ((snippet-p (completion-snippet-p item)))
      (lambda (point start end)
        (let* ((buffer (point-buffer point))
               (installer
                 (when snippet-p
                   (prepare-completion-snippet text label buffer)))
               (additional-text-edits
                 (resolve-completion-additional-text-edits item workspace))
               (main-start (copy-point start :left-inserting))
               (main-end (copy-point end :right-inserting))
               (edits nil))
          (unwind-protect
               (when (or (not snippet-p) installer)
                 (multiple-value-bind (prepared-edits valid-p)
                   (prepare-completion-text-edits
                      buffer additional-text-edits main-start main-end snapshot)
                   (setf edits prepared-edits)
                   (unless valid-p
                     (message "Ignoring invalid or overlapping LSP additionalTextEdits"))
                   (call-with-completion-change-group
                    buffer
                    (lambda ()
                      (handler-case
                          (progn
                            (ensure-completion-edits-writable
                             edits main-start main-end)
                            (apply-completion-text-edits edits)
                            (if snippet-p
                                (funcall installer main-start main-end)
                                (progn
                                  (delete-between-points main-start main-end)
                                  (move-point point main-start)
                                  (insert-string point text)
                                  t)))
                        (read-only-error (condition)
                          (message "Cannot apply read-only LSP completion: ~A"
                                   condition)
                          nil))))))
            (when edits
              (delete-completion-text-edit-points edits))
            (delete-point main-start)
            (delete-point main-end)))))))

(defun convert-completion-items (point items &optional workspace)
  (let ((snapshot-text (buffer-text (point-buffer point)))
        (snapshot-encoding (workspace-position-encoding workspace)))
    (labels ((sort-items (items)
             (sort items #'string< :key #'completion-item-sort-text))
           (original-range-points (start end)
             (values
              (or start
                  (with-point ((range-start point))
                    (skip-chars-backward range-start #'syntax-symbol-char-p)
                    range-start))
              (or end point)))
           (label-filter-insert-and-points (item)
             (let* ((label (lsp:completion-item-label item))
                    (filter-text
                      (completion-item-nonempty-string
                       #'lsp:completion-item-filter-text item label))
                    (insert-text
                      (completion-item-nonempty-string
                       #'lsp:completion-item-insert-text item label))
                    (text-edit
                      (optional-completion-item-value
                       #'lsp:completion-item-text-edit item)))
               (typecase text-edit
                 (lsp:text-edit
                  (list* label
                         filter-text
                         (lsp:text-edit-new-text text-edit)
                         (convert-to-range
                          point (lsp:text-edit-range text-edit) workspace)))
                 (lsp:insert-replace-edit
                  (list* label
                         filter-text
                         (lsp:insert-replace-edit-new-text text-edit)
                         (convert-insert-replace-range
                          point text-edit workspace)))
                 (otherwise
                  (list label filter-text insert-text nil nil)))))
           (make-completion-item-unsafe (item)
             (destructuring-bind (label filter-text insert-text start end)
                 (label-filter-insert-and-points item)
               (multiple-value-bind (range-start range-end)
                   (original-range-points start end)
                 (let ((snapshot
                         (make-completion-document-snapshot
                          :text snapshot-text
                          :encoding snapshot-encoding
                          :main-start-offset
                          (1- (position-at-point range-start))
                          :main-end-offset
                          (1- (position-at-point range-end)))))
                   (make-instance
                    'completion-item
                    :start start
                    :end end
                    :label label
                    :filter-text filter-text
                    :insert-text insert-text
                    :final-insert-action
                    (completion-final-insert-action
                     item workspace insert-text label snapshot)
                    :detail (handler-case (lsp:completion-item-detail item)
                              (unbound-slot () ""))
                    :sort-text
                    (completion-item-nonempty-string
                     #'lsp:completion-item-sort-text item label)
                    :focus-action
                    (when-let* ((documentation
                                  (handler-case
                                      (lsp:completion-item-documentation item)
                                    (unbound-slot () nil)))
                                 (result
                                   (contents-to-markdown-buffer documentation)))
                      (lambda (context)
                        (display-message
                         result
                         :style `(:gravity :vertically-adjacent-window
                                  :offset-y -1
                                  :offset-x 1)
                         :source-window
                         (lem/popup-menu::popup-menu-window
                          (lem/completion-mode::context-popup-menu
                           context))))))))))
           (make-completion-item (item)
             (handler-case (make-completion-item-unsafe item)
               (error (condition)
                 (log:warn "Ignoring malformed LSP completion item: ~A"
                           condition)
                 nil))))
      (sort-items
       (remove nil
               (map 'list
                    #'make-completion-item
                    items))))))

(defun convert-completion-list (point completion-list &optional workspace)
  (convert-completion-items
   point (lsp:completion-list-items completion-list) workspace))

(defun convert-completion-response (point value &optional workspace)
  (cond ((typep value 'lsp:completion-list)
         (convert-completion-list point value workspace))
        ((lsp-array-p value)
         (convert-completion-items point value workspace))
        (t
         nil)))

(defun provide-completion-p (workspace)
  (handler-case (lsp:server-capabilities-completion-provider
                 (workspace-server-capabilities workspace))
    (unbound-slot () nil)))

(defun filter-completion-items (input items)
  "Retain Lem's native LSP fuzzy filtering when no client overrides it."
  (completion-strings input
                      items
                      :key #'completion:completion-item-filter-text))

(defun text-document/completion (point then)
  (let* ((buffer (point-buffer point))
         (workspace (buffer-workspace buffer nil)))
    (if (and workspace
             (eq :ready (workspace-state workspace))
             (provide-completion-p workspace))
        (async-request
         (workspace-client workspace)
         (make-instance 'lsp:text-document/completion)
         (apply #'make-instance
                'lsp:completion-params
         (make-text-document-position-arguments point workspace))
         :then (lambda (response)
                 (if (workspace-response-current-p workspace buffer)
                     (let ((items
                             (handler-case
                                 (convert-completion-response
                                  point response workspace)
                               (error (condition)
                                 (message
                                  "Ignoring malformed LSP completion response: ~A"
                                  condition)
                                 nil))))
                       (funcall then items))
                     (funcall then nil)))
         :error (lambda (message code)
                  (declare (ignore message code))
                  (funcall then nil)))
        (funcall then nil))))

(defun completion-with-trigger-character (c)
  (declare (ignore c))
  (check-connection)
  (language-mode::complete-symbol))

;;; signatureHelp

(define-attribute signature-help-active-parameter-attribute
  (t :background :base0D :underline t))

(defun provide-signature-help-p (workspace)
  (handler-case (lsp:server-capabilities-signature-help-provider
                 (workspace-server-capabilities workspace))
    (unbound-slot () nil)))

(defun insert-markdown (point markdown-text)
  (insert-buffer point (lem/markdown-buffer:markdown-buffer markdown-text)))

(defun insert-markup-content (point markup-content)
  (switch ((lsp:markup-content-kind markup-content) :test #'equal)
    ("markdown"
     (insert-markdown point (lsp:markup-content-value markup-content)))
    ("plaintext"
     (insert-string point (lsp:markup-content-value markup-content)))
    (otherwise
     (insert-string point (lsp:markup-content-value markup-content)))))

(defun insert-documentation (point documentation)
  (insert-character point #\newline)
  (etypecase documentation
    (lsp:markup-content
     (insert-markup-content point documentation))
    (string
     (insert-string point documentation))))

(defun highlight-signature-active-parameter (point parameters active-parameter)
  (with-point ((point point))
    (buffer-start point)
    (do-sequence ((parameter index) parameters)
      (let ((label (lsp:parameter-information-label parameter)))
        ;; TODO:
        ;; Handle the case where the label's type is [number, number]
        (when (stringp label)
          (search-forward point label)
          (when (= active-parameter index)
            (with-point ((start point))
              (character-offset start (- (length label)))
              (put-text-property start
                                 point
                                 :attribute 'signature-help-active-parameter-attribute)
              (return-from highlight-signature-active-parameter))))))))

(defun highlight-signature (point signature active-parameter)
  (let ((parameters
          (handler-case (lsp:signature-information-parameters signature)
            (unbound-slot () nil)))
        (active-parameter
          (handler-case (lsp:signature-information-active-parameter signature)
            (unbound-slot () active-parameter))))
    (when (and (plusp (length parameters))
               (< active-parameter (length parameters)))
      (highlight-signature-active-parameter point
                                            parameters
                                            active-parameter))))

(defun make-signature-help-buffer (signature-help)
  (let ((buffer (make-temporary-unwrap-buffer))
        (active-parameter
          (handler-case (lsp:signature-help-active-parameter signature-help)
            (unbound-slot () 0)))
        (active-signature
          (handler-case (lsp:signature-help-active-signature signature-help)
            (unbound-slot () nil)))
        (signatures (lsp:signature-help-signatures signature-help)))
    (do-sequence ((signature index) signatures)
      (let ((point (buffer-point buffer)))
        (when (plusp index) (insert-character point #\newline))
        (insert-string point (lsp:signature-information-label signature))
        (when (or (eql index active-signature)
                  (length= 1 signatures))
          (highlight-signature point signature active-parameter))
        (insert-character point #\newline)
        (handler-case (lsp:signature-information-documentation signature)
          (unbound-slot () nil)
          (:no-error (documentation)
            (insert-documentation point documentation)))))
    (buffer-start (buffer-point buffer))
    buffer))

(defun display-signature-help (signature-help)
  (let ((buffer (make-signature-help-buffer signature-help)))
    (display-message buffer)))

(defun text-document/signature-help (point &optional signature-help-context)
  (let ((buffer (point-buffer point)))
    (when-let ((workspace (get-workspace-from-point point)))
    (when (provide-signature-help-p workspace)
      (async-request (workspace-client workspace)
                     (make-instance 'lsp:text-document/signature-help)
                     (apply #'make-instance
                            'lsp:signature-help-params
                            (append (when signature-help-context
                                      `(:context ,signature-help-context))
                                    (make-text-document-position-arguments
                                     point workspace)))
                     :then (lambda (result)
                             (when (and
                                    (workspace-response-current-p
                                     workspace buffer)
                                    (not (lsp-null-p result)))
                               (display-signature-help result)
                               (redraw-display))))
                     :error (lambda (message code)
                              (feature-request-error
                               workspace buffer message code))))))

(defun lsp-signature-help-with-trigger-character (character)
  (text-document/signature-help
   (current-point)
   (make-instance 'lsp:signature-help-context
                  :trigger-kind lsp:signature-help-trigger-kind-trigger-character
                  :trigger-character (string character)
                  :is-retrigger +false+
                  #|:active-signature-help|#)))

(define-command lsp-signature-help () ()
  (check-connection)
  (text-document/signature-help (current-point)
                                (make-instance 'lsp:signature-help-context
                                               :trigger-kind lsp:signature-help-trigger-kind-invoked
                                               :is-retrigger +false+)))

;;; declaration

(defun provide-declaration-p (workspace)
  (handler-case (lsp:server-capabilities-declaration-provider
                 (workspace-server-capabilities workspace))
    (unbound-slot () nil)))

(defun text-document/declaration (point)
  (declare (ignore point))
  ;; TODO:
  ;; not supported by `gopls`, delaying to later
  nil)

;;; definition

(defun provide-definition-p (workspace)
  (handler-case (lsp:server-capabilities-definition-provider
                 (workspace-server-capabilities workspace))
    (unbound-slot () nil)))

(defun definition-location-to-content (buffer location workspace)
  (when-let* ((point (buffer-point buffer))
              (range (lsp:location-range location)))
    (with-point ((start point)
                 (end point))
      (when (and
             (move-to-workspace-position
              start (lsp:range-start range) workspace)
             (move-to-workspace-position
              end (lsp:range-end range) workspace)
             (point<= start end))
        (line-start start)
        (line-end end)
        (points-to-string start end)))))

(defgeneric convert-location (location workspace)
  (:method ((location lsp:location) workspace)
    ;; TODO:
    ;; Also use `end-position`.
    ;; After moving to definition location, set the highlight to the start/end range.
    (let* ((start-position (lsp:range-start (lsp:location-range location)))
           (end-position (lsp:range-end (lsp:location-range location)))
           (uri (lsp:location-uri location))
           (file (ignore-errors (uri-to-pathname uri))))
      (declare (ignore end-position))
      (when (and file (uiop:file-exists-p file))
        (when-let* ((buffer (find-file-buffer file))
                    (content
                      (definition-location-to-content
                       buffer location workspace)))
          (with-point ((point (buffer-point buffer)))
            (when (move-to-workspace-position
                   point start-position workspace)
              (language-mode:make-xref-location
               :filespec file
               :position (point-to-xref-position point)
               :content content)))))))
  (:method ((location lsp:location-link) workspace)
    (declare (ignore workspace))
    (error "locationLink is unsupported")))

(defun convert-definition-response (value workspace)
  (remove nil
          (cond ((typep value 'lsp:location)
                 (list (convert-location value workspace)))
                ((lsp-array-p value)
                 ;; TODO: location-link
                 (map 'list
                      (lambda (location)
                        (convert-location location workspace))
                      value))
                (t
                 nil))))

(defun text-document/definition (point then)
  (let ((buffer (point-buffer point)))
    (when-let ((workspace (get-workspace-from-point point)))
    (when (provide-definition-p workspace)
      (async-request
       (workspace-client workspace)
       (make-instance 'lsp:text-document/definition)
       (apply #'make-instance
              'lsp:definition-params
       (make-text-document-position-arguments point workspace))
       :then (lambda (response)
               (when (workspace-response-current-p workspace buffer)
                 (funcall then
                          (convert-definition-response response workspace))
                 (redraw-display)))
       :error (lambda (message code)
                (feature-request-error
                 workspace buffer message code)))))))

(defun lsp-find-definitions (point)
  (check-connection)
  (text-document/definition point #'language-mode:display-xref-locations))

;;; type definition

(defun provide-type-definition-p (workspace)
  (handler-case (lsp:server-capabilities-type-definition-provider
                 (workspace-server-capabilities workspace))
    (unbound-slot () nil)))

(defun convert-type-definition-response (value workspace)
  (convert-definition-response value workspace))

(defun text-document/type-definition (point then)
  (let ((buffer (point-buffer point)))
    (when-let ((workspace (get-workspace-from-point point)))
    (when (provide-type-definition-p workspace)
      (async-request (workspace-client workspace)
                     (make-instance 'lsp:text-document/type-definition)
                     (apply #'make-instance
                            'lsp:type-definition-params
                            (make-text-document-position-arguments point workspace))
                     :then (lambda (response)
                             (when (workspace-response-current-p
                                    workspace buffer)
                               (funcall then
                                        (convert-type-definition-response
                                         response workspace))))
                     :error (lambda (message code)
                              (feature-request-error
                               workspace buffer message code)))))))

(define-command lsp-type-definition () ()
  (check-connection)
  (text-document/type-definition (current-point) #'language-mode:display-xref-locations))

;;; implementation

(defun provide-implementation-p (workspace)
  (handler-case (lsp:server-capabilities-implementation-provider
                 (workspace-server-capabilities workspace))
    (unbound-slot () nil)))

(defun convert-implementation-response (value workspace)
  (convert-definition-response value workspace))

(defun text-document/implementation (point then)
  (let ((buffer (point-buffer point)))
    (when-let ((workspace (get-workspace-from-point point)))
    (when (provide-implementation-p workspace)
      (async-request (workspace-client workspace)
                     (make-instance 'lsp:text-document/implementation)
                     (apply #'make-instance
                            'lsp:type-definition-params
                            (make-text-document-position-arguments point workspace))
                     :then (lambda (response)
                             (when (workspace-response-current-p
                                    workspace buffer)
                               (funcall then
                                        (convert-implementation-response
                                         response workspace))))
                     :error (lambda (message code)
                              (feature-request-error
                               workspace buffer message code)))))))

(define-command lsp-implementation () ()
  (check-connection)
  (text-document/implementation (current-point)
                                #'language-mode:display-xref-locations))

;;; references

(defun provide-references-p (workspace)
  (handler-case (lsp:server-capabilities-references-provider
                 (workspace-server-capabilities workspace))
    (unbound-slot () nil)))

(defun xref-location-to-content (location)
  (when-let*
      ((buffer (find-file-buffer (language-mode:xref-location-filespec location) :temporary t))
       (point (buffer-point buffer)))
    (language-mode::move-to-location-position
     point
     (language-mode:xref-location-position location))
    (string-trim '(#\space #\tab) (line-string point))))

(defun convert-references-response (value workspace)
  (language-mode:make-xref-references
   :type nil
   :locations (mapcar (lambda (location)
                        (language-mode:make-xref-location
                         :filespec (language-mode:xref-location-filespec location)
                         :position (language-mode:xref-location-position location)
                         :content (xref-location-to-content location)))
                      (convert-definition-response value workspace))))

(defun text-document/references (point then &optional include-declaration)
  (let ((buffer (point-buffer point)))
    (when-let ((workspace (get-workspace-from-point point)))
    (when (provide-references-p workspace)
      (async-request
       (workspace-client workspace)
       (make-instance 'lsp:text-document/references)
       (apply #'make-instance
              'lsp:reference-params
              :context (make-instance 'lsp:reference-context
                                      :include-declaration include-declaration)
       (make-text-document-position-arguments point workspace))
       :then (lambda (response)
               (when (workspace-response-current-p workspace buffer)
                 (funcall then
                          (convert-references-response response workspace))
                 (redraw-display)))
       :error (lambda (message code)
                (feature-request-error
                 workspace buffer message code)))))))

(defun lsp-find-references (point)
  (check-connection)
  (text-document/references point
                            #'language-mode:display-xref-references))

;;; document highlights

(define-attribute document-highlight-text-attribute
  (t :background :base02))

(defun provide-document-highlight-p (workspace)
  (handler-case (lsp:server-capabilities-document-highlight-provider
                 (workspace-server-capabilities workspace))
    (unbound-slot () nil)))

(defstruct document-highlight-context
  (overlays '())
  (last-modified-tick 0))

(defvar *document-highlight-context* (make-document-highlight-context))

(defun document-highlight-overlays ()
  (document-highlight-context-overlays *document-highlight-context*))

(defun (setf document-highlight-overlays) (value)
  (setf (document-highlight-context-overlays *document-highlight-context*)
        value))

(defun cursor-in-document-highlight-p ()
  (dolist (ov (document-highlight-overlays))
    (unless (eq (current-buffer) (overlay-buffer ov))
      (return nil))
    (when (point<= (overlay-start ov) (current-point) (overlay-end ov))
      (return t))))

(defun clear-document-highlight-overlays ()
  (mapc #'delete-overlay (document-highlight-overlays))
  (setf (document-highlight-overlays) '())
  (setf (document-highlight-context-last-modified-tick *document-highlight-context*)
        (buffer-modified-tick (current-buffer))))

(defun clear-document-highlight-overlays-if-required ()
  (when (or (not (cursor-in-document-highlight-p))
            (not (= (document-highlight-context-last-modified-tick *document-highlight-context*)
                    (buffer-modified-tick (current-buffer))))
            (mode-active-p (current-buffer) 'lem/isearch:isearch-mode))
    (clear-document-highlight-overlays)
    t))

(defun display-document-highlights (workspace buffer document-highlights)
  (with-point ((start (buffer-point buffer))
               (end (buffer-point buffer)))
    (do-sequence (document-highlight document-highlights)
      (let ((range (lsp:document-highlight-range document-highlight)))
        (when (and
               (move-to-workspace-position
                start (lsp:range-start range) workspace)
               (move-to-workspace-position
                end (lsp:range-end range) workspace)
               (point<= start end))
          (push (make-overlay start end 'document-highlight-text-attribute)
                (document-highlight-overlays)))))))

(defun text-document/document-highlight (point)
  (let ((buffer (point-buffer point)))
    (when-let ((workspace (get-workspace-from-point point)))
    (when (and (workspace-response-current-p workspace buffer)
               (provide-document-highlight-p workspace))
      (unless (cursor-in-document-highlight-p)
        (let ((counter (command-loop-counter)))
          (async-request
           (workspace-client workspace)
           (make-instance 'lsp:text-document/document-highlight)
           (apply #'make-instance
                  'lsp:document-highlight-params
                  (make-text-document-position-arguments point workspace))
           :then (lambda (value)
                   (when (and (workspace-response-current-p workspace buffer)
                              (not (lsp-null-p value)))
                     (when (= counter (command-loop-counter))
                       (display-document-highlights
                        workspace buffer value)
                       (redraw-display)))))
           :error (lambda (message code)
                    (feature-request-error
                     workspace buffer message code))))))))

(defun document-highlight-calls-timer ()
  (when (mode-active-p (current-buffer) 'lsp-mode)
    (when (buffer-workspace (current-buffer) nil)
      (text-document/document-highlight (current-point)))))

(define-command lsp-document-highlight () ()
  (when (mode-active-p (current-buffer) 'lsp-mode)
    (check-connection)
    (text-document/document-highlight (current-point))))

(defvar *document-highlight-idle-timer* nil)

(defun enable-document-highlight-idle-timer ()
  (unless *document-highlight-idle-timer*
    (setf *document-highlight-idle-timer*
          (start-timer (make-idle-timer #'document-highlight-calls-timer
                                        :name "lsp-document-highlight")
                       200
                       :repeat t))))

(defmethod execute :after ((mode lsp-mode) command argument)
  (declare (ignore mode command argument))
  (let* ((buffer (current-buffer))
         (workspace (buffer-value buffer 'lsp-workspace)))
    (when (and workspace
               (not (lsp-buffer-attachment-valid-p buffer workspace)))
      (rebind-lsp-buffer buffer workspace)))
  (clear-document-highlight-overlays-if-required))

;;; document symbols

;; TODO
;; - Sort by `position`

(define-attribute symbol-kind-file-attribute
  (t :foreground "snow1"))

(define-attribute symbol-kind-module-attribute
  (t :foreground "firebrick"))

(define-attribute symbol-kind-namespace-attribute
  (t :foreground "dark orchid"))

(define-attribute symbol-kind-package-attribute
  (t :foreground "green"))

(define-attribute symbol-kind-class-attribute
  (t :foreground "bisque2"))

(define-attribute symbol-kind-method-attribute
  (t :foreground "MediumPurple2"))

(define-attribute symbol-kind-property-attribute
  (t :foreground "MistyRose4"))

(define-attribute symbol-kind-field-attribute
  (t :foreground "azure3"))

(define-attribute symbol-kind-constructor-attribute
  (t :foreground "LightSkyBlue3"))

(define-attribute symbol-kind-enum-attribute
  (t :foreground "LightCyan4"))

(define-attribute symbol-kind-interface-attribute
  (t :foreground "gray78"))

(define-attribute symbol-kind-function-attribute
  (t :foreground "LightSkyBlue"))

(define-attribute symbol-kind-variable-attribute
  (t :foreground "LightGoldenrod"))

(define-attribute symbol-kind-constant-attribute
  (t :foreground "yellow2"))

(define-attribute symbol-kind-string-attribute
  (t :foreground "green"))

(define-attribute symbol-kind-number-attribute
  (t :foreground "yellow"))

(define-attribute symbol-kind-boolean-attribute
  (t :foreground "honeydew3"))

(define-attribute symbol-kind-array-attribute
  (t :foreground "red"))

(define-attribute symbol-kind-object-attribute
  (t :foreground "PeachPuff4"))

(define-attribute symbol-kind-key-attribute
  (t :foreground "lime green"))

(define-attribute symbol-kind-null-attribute
  (t :foreground "gray"))

(define-attribute symbol-kind-enum-member-attribute
  (t :foreground "PaleTurquoise4"))

(define-attribute symbol-kind-struct-attribute
  (t :foreground "turquoise4"))

(define-attribute symbol-kind-event-attribute
  (t :foreground "aquamarine1"))

(define-attribute symbol-kind-operator-attribute
  (t :foreground "SeaGreen3"))

(define-attribute symbol-kind-type-attribute
  (t :foreground "moccasin"))

(defun preview-symbol-kind-colors ()
  (let* ((buffer (make-buffer "symbol-kind-colors"))
         (point (buffer-point buffer)))
    (dolist (attribute
             (list 'symbol-kind-file-attribute
                   'symbol-kind-module-attribute
                   'symbol-kind-namespace-attribute
                   'symbol-kind-package-attribute
                   'symbol-kind-class-attribute
                   'symbol-kind-method-attribute
                   'symbol-kind-property-attribute
                   'symbol-kind-field-attribute
                   'symbol-kind-constructor-attribute
                   'symbol-kind-enum-attribute
                   'symbol-kind-interface-attribute
                   'symbol-kind-function-attribute
                   'symbol-kind-variable-attribute
                   'symbol-kind-constant-attribute
                   'symbol-kind-string-attribute
                   'symbol-kind-number-attribute
                   'symbol-kind-boolean-attribute
                   'symbol-kind-array-attribute
                   'symbol-kind-object-attribute
                   'symbol-kind-key-attribute
                   'symbol-kind-null-attribute
                   'symbol-kind-enum-member-attribute
                   'symbol-kind-struct-attribute
                   'symbol-kind-event-attribute
                   'symbol-kind-operator-attribute
                   'symbol-kind-type-attribute))
      (insert-string point (string-downcase attribute) :attribute attribute)
      (insert-character point #\newline))))

(defun provide-document-symbol-p (workspace)
  (handler-case (lsp:server-capabilities-document-symbol-provider
                 (workspace-server-capabilities workspace))
    (unbound-slot () nil)))

(defun symbol-kind-to-string-and-attribute (symbol-kind)
  (switch (symbol-kind :test #'=)
    (lsp:symbol-kind-file
     (values "File" 'symbol-kind-file-attribute))
    (lsp:symbol-kind-module
     (values "Module" 'symbol-kind-module-attribute))
    (lsp:symbol-kind-namespace
     (values "Namespace" 'symbol-kind-namespace-attribute))
    (lsp:symbol-kind-package
     (values "Package" 'symbol-kind-package-attribute))
    (lsp:symbol-kind-class
     (values "Class" 'symbol-kind-class-attribute))
    (lsp:symbol-kind-method
     (values "Method" 'symbol-kind-method-attribute))
    (lsp:symbol-kind-property
     (values "Property" 'symbol-kind-property-attribute))
    (lsp:symbol-kind-field
     (values "Field" 'symbol-kind-field-attribute))
    (lsp:symbol-kind-constructor
     (values "Constructor" 'symbol-kind-constructor-attribute))
    (lsp:symbol-kind-enum
     (values "Enum" 'symbol-kind-enum-attribute))
    (lsp:symbol-kind-interface
     (values "Interface" 'symbol-kind-interface-attribute))
    (lsp:symbol-kind-function
     (values "Function" 'symbol-kind-function-attribute))
    (lsp:symbol-kind-variable
     (values "Variable" 'symbol-kind-variable-attribute))
    (lsp:symbol-kind-constant
     (values "Constant" 'symbol-kind-constant-attribute))
    (lsp:symbol-kind-string
     (values "String" 'symbol-kind-string-attribute))
    (lsp:symbol-kind-number
     (values "Number" 'symbol-kind-number-attribute))
    (lsp:symbol-kind-boolean
     (values "Boolean" 'symbol-kind-boolean-attribute))
    (lsp:symbol-kind-array
     (values "Array" 'symbol-kind-array-attribute))
    (lsp:symbol-kind-object
     (values "Object" 'symbol-kind-object-attribute))
    (lsp:symbol-kind-key
     (values "Key" 'symbol-kind-key-attribute))
    (lsp:symbol-kind-null
     (values "Null" 'symbol-kind-null-attribute))
    (lsp:symbol-kind-enum-member
     (values "EnumMember" 'symbol-kind-enum-member-attribute))
    (lsp:symbol-kind-struct
     (values "Struct" 'symbol-kind-struct-attribute))
    (lsp:symbol-kind-event
     (values "Event" 'symbol-kind-event-attribute))
    (lsp:symbol-kind-operator
     (values "Operator" 'symbol-kind-operator-attribute))
    (lsp:symbol-kind-type-parameter
     (values "TypeParameter" 'symbol-kind-type-attribute))))

(define-attribute document-symbol-detail-attribute
  (t :foreground :base04))

(defun append-document-symbol-item (workspace buffer document-symbol nest-level)
  (let ((selection-range (lsp:document-symbol-selection-range document-symbol))
        (range (lsp:document-symbol-range document-symbol)))
    (declare (ignore range)) ; TODO: use `range` in region highlighting
    (when (with-point ((point (buffer-point buffer)))
            (move-to-workspace-position
             point (lsp:range-start selection-range) workspace))
      (lem/peek-source:with-appending-source
          (point :move-function (lambda ()
                                  (let ((point (buffer-point buffer)))
                                    (move-to-workspace-position
                                     point
                                     (lsp:range-start selection-range)
                                     workspace))))
        (multiple-value-bind (kind-name attribute)
            (symbol-kind-to-string-and-attribute
             (lsp:document-symbol-kind document-symbol))
          (insert-string
           point (make-string (* 2 nest-level) :initial-element #\space))
          (insert-string point (format nil "[~A]" kind-name) :attribute attribute)
          (insert-character point #\space)
          (insert-string point (lsp:document-symbol-name document-symbol))
          (insert-string point " ")
          (when-let (detail
                     (handler-case
                         (lsp:document-symbol-detail document-symbol)
                       (unbound-slot () nil)))
            (insert-string
             point detail :attribute 'document-symbol-detail-attribute))))))
  (do-sequence
      (document-symbol
      (handler-case (lsp:document-symbol-children document-symbol)
         (unbound-slot () nil)))
    (append-document-symbol-item
     workspace buffer document-symbol (1+ nest-level))))

(defun display-document-symbol-response (workspace buffer value)
  (lem/peek-source:with-collecting-sources (collector)
    (do-sequence (item value)
      (append-document-symbol-item workspace buffer item 0))))

(defun text-document/document-symbol (buffer)
  (when-let ((workspace (buffer-workspace buffer)))
    (when (provide-document-symbol-p workspace)
      (request:request
       (workspace-client workspace)
       (make-instance 'lsp:text-document/document-symbol)
       (make-instance
        'lsp:document-symbol-params
        :text-document (make-text-document-identifier buffer))))))

(define-command lsp-document-symbol () ()
  (check-connection)
  (let* ((buffer (current-buffer))
         (workspace (buffer-workspace buffer)))
    (display-document-symbol-response
     workspace buffer (text-document/document-symbol buffer))))

;;; code action
;; TODO
;; - codeAction.diagnostics
;; - codeAction.isPreferred

(defun provide-code-action-p (workspace)
  (handler-case (lsp:server-capabilities-code-action-provider
                 (workspace-server-capabilities workspace))
    (unbound-slot () nil)))

(defun execute-command (workspace command)
  ;; TODO
  ;; Need to look at response, and deal with it somehow.
  ;; This feature isn't currently used by `gopls`, so its behavior hasn't been tested.
  (request:request
   (workspace-client workspace)
   (make-instance 'lsp:workspace/execute-command)
   (make-instance 'lsp:execute-command-params
                  :command (lsp:command-command command)
                  :arguments (lsp:command-arguments command))))

(defun execute-code-action (workspace code-action)
  (handler-case (lsp:code-action-edit code-action)
    (unbound-slot () nil)
    (:no-error (workspace-edit)
      (apply-workspace-edit workspace workspace-edit)))
  (handler-case (lsp:code-action-command code-action)
    (unbound-slot () nil)
    (:no-error (command)
      (execute-command workspace command))))

(defun convert-code-actions (code-actions workspace)
  (let ((items '()))
    (do-sequence (command-or-code-action code-actions)
      (etypecase command-or-code-action
        (lsp:code-action
         (let ((code-action command-or-code-action))
           (push (make-instance 'context-menu:item
                                :label (lsp:code-action-title code-action)
                                :callback (lambda (window)
                                            (declare (ignore window))
                                            (execute-code-action workspace code-action)))
                 items)))
        (lsp:command
         (let ((command command-or-code-action))
           (push (make-instance 'context-menu:item
                                :label (lsp:command-title command)
                                :callback (lambda (window)
                                            (declare (ignore window))
                                            (execute-command workspace command)))
                 items)))))
    (nreverse items)))

(defun text-document/code-action (point)
  (flet ((point-to-line-range (point workspace)
           (with-point ((start point)
                        (end point))
             (line-start start)
             (line-end end)
             (points-to-workspace-range start end workspace))))
    (when-let ((workspace (get-workspace-from-point point)))
      (when (provide-code-action-p workspace)
        (request:request
         (workspace-client workspace)
         (make-instance 'lsp:text-document/code-action)
         (make-instance
          'lsp:code-action-params
          :text-document (make-text-document-identifier (point-buffer point))
          :range (point-to-line-range point workspace)
          :context (make-instance 'lsp:code-action-context
                                  :diagnostics (make-lsp-array))))))))

(define-command lsp-code-action () ()
  (check-connection)
  (let ((response (text-document/code-action (current-point)))
        (workspace (buffer-workspace (current-buffer))))
    (cond ((typep response 'lsp:command)
           (execute-command workspace response))
          ((and (lsp-array-p response)
                (not (length= response 0)))
           (context-menu:display-context-menu
            (convert-code-actions response
                                  workspace)))
          (t
           (message "No suggestions from code action")))))

(defun find-organize-imports (code-actions)
  (do-sequence (code-action code-actions)
    (when (equal "source.organizeImports" (lsp:code-action-kind code-action))
      (return-from find-organize-imports code-action))))

(defun organize-imports (buffer)
  (let ((response (text-document/code-action (buffer-point buffer)))
        (workspace (buffer-workspace buffer)))
    (unless (lsp-null-p response)
      (let ((code-action (find-organize-imports response)))
        (unless (lsp-null-p code-action)
          (execute-code-action workspace code-action))))))

(define-command lsp-organize-imports () ()
  (organize-imports (current-buffer)))

;;; formatting

(defun provide-formatting-p (workspace)
  (handler-case (lsp:server-capabilities-document-formatting-provider
                 (workspace-server-capabilities workspace))
    (unbound-slot () nil)))

(defun make-formatting-options (buffer)
  (make-instance
   'lsp:formatting-options
   :tab-size (or (variable-value 'tab-width :buffer buffer) +default-tab-size+)
   :insert-spaces (not (variable-value 'indent-tabs-mode :buffer buffer))
   :trim-trailing-whitespace t
   :insert-final-newline t
   :trim-final-newlines t))

(defun text-document/formatting (buffer)
  (when-let ((workspace (buffer-workspace buffer)))
    (when (provide-formatting-p workspace)
      (apply-text-edits
       buffer
       (request:request
        (workspace-client workspace)
        (make-instance 'lsp:text-document/formatting)
        (make-instance
         'lsp:document-formatting-params
         :text-document (make-text-document-identifier buffer)
         :options (make-formatting-options buffer)))
       workspace))))

(define-command lsp-document-format () ()
  (check-connection)
  (text-document/formatting (current-buffer)))

;;; range formatting

;; WARNING: This is unsupported by `gopls`, so behavior is not tested.

(defun provide-range-formatting-p (workspace)
  (handler-case (lsp:server-capabilities-document-range-formatting-provider
                 (workspace-server-capabilities workspace))
    (unbound-slot () nil)))

(defun text-document/range-formatting (start end)
  (when (point< end start) (rotatef start end))
  (let ((buffer (point-buffer start)))
    (when-let ((workspace (buffer-workspace buffer)))
      (when (provide-range-formatting-p workspace)
        (apply-text-edits
         buffer
         (request:request
          (workspace-client workspace)
          (make-instance 'lsp:text-document/range-formatting)
          (make-instance
           'lsp:document-range-formatting-params
           :text-document (make-text-document-identifier buffer)
           :range (points-to-workspace-range start end workspace)
           :options (make-formatting-options buffer)))
         workspace)))))

(define-command lsp-document-range-format (start end) (:region)
  (check-connection)
  (text-document/range-formatting start end))

;;; onTypeFormatting

;; TODO
;; - Add a hook to call `text-document/on-type-formatting` when buffer is initialized

(defun provide-on-type-formatting-p (workspace)
  (handler-case (lsp:server-capabilities-document-on-type-formatting-provider
                 (workspace-server-capabilities workspace))
    (unbound-slot () nil)))

(defun text-document/on-type-formatting (point typed-character)
  (when-let ((workspace (get-workspace-from-point point)))
    (when (provide-on-type-formatting-p workspace)
      (when-let ((response
                  (with-jsonrpc-error ()
                    (request:request
                     (workspace-client workspace)
                     (make-instance 'lsp:text-document-client-capabilities-on-type-formatting)
                     (apply #'make-instance
                            'lsp:document-on-type-formatting-params
                            :ch typed-character
                            :options (make-formatting-options (point-buffer point))
                            (make-text-document-position-arguments
                             point workspace))))))
        (apply-text-edits (point-buffer point) response workspace)))))

;;; rename

;; TODO
;; - prepareSupport

(defun provide-rename-p (workspace)
  (handler-case (lsp:server-capabilities-rename-provider
                 (workspace-server-capabilities workspace))
    (unbound-slot () nil)))

(defun text-document/rename (point new-name)
  (when-let ((workspace (get-workspace-from-point point)))
    (when (provide-rename-p workspace)
      (when-let ((response
                  (with-jsonrpc-error ()
                    (request:request
                     (workspace-client workspace)
                     (make-instance 'lsp:text-document/rename)
                     (apply #'make-instance
                            'lsp:rename-params
                            :new-name new-name
                            (make-text-document-position-arguments
                             point workspace))))))
        (apply-workspace-edit workspace response)))))

(define-command lsp-rename (new-name) ((:string "New name: "))
  (check-connection)
  (text-document/rename (current-point) new-name))

;;;
(define-command lsp-shutdown-server () ()
  (let* ((buffer (current-buffer))
         (workspace
           (or (buffer-workspace buffer nil)
               (when (lsp-buffer-eligible-p buffer)
                 (find-workspace-for-buffer
                  (buffer-language-spec buffer) buffer)))))
    (unless workspace
      (editor-error "No LSP workspace for this project."))
    (let ((buffers (copy-list (workspace-buffers workspace))))
      (dispose-workspace workspace)
      (dolist (owned-buffer buffers)
        (disable-lsp-mode-for-buffer owned-buffer)))
    (show-message "LSP workspace stopped.")))

(define-command lsp-restart-server () ()
  (let* ((current (current-buffer))
         (workspace (buffer-workspace current nil))
         (buffers
           (if workspace
               (remove-if #'deleted-buffer-p
                          (copy-list (workspace-buffers workspace)))
               (list current))))
    (setf buffers
          (remove-if-not #'lsp-buffer-eligible-p
                         (cons current (delete current buffers))))
    (cond
      ((and workspace buffers)
       (let ((spec (workspace-spec workspace)))
         (dispose-workspace workspace)
         (handler-case
             (restart-workspace spec workspace buffers)
           (error (condition)
             (dolist (buffer buffers)
               (disable-lsp-mode-for-buffer buffer))
             (error condition)))))
      (buffers
       (with-current-buffer (first buffers)
         (lsp-mode t))))))

;;;
(defun enable-lsp-mode ()
  "This function is called when the corresponding major mode is enabled,
because lsp-mode acts as a minor mode for the corresponding major mode."
  (unless (or (eq *disable* t)
              (eq *disable* (current-buffer))
              (not (lsp-buffer-eligible-p (current-buffer))))
    (lsp-mode t)))

(defmacro define-language-spec ((spec-name major-mode &key (parent-spec 'lem-lsp-mode/spec::spec)) &body initargs)
  `(progn
     ,(when (mode-hook-variable major-mode)
        `(add-hook ,(mode-hook-variable major-mode) 'enable-lsp-mode))
     (eval-when (:compile-toplevel :load-toplevel :execute)
       (defclass ,spec-name (,parent-spec) ()
         (:default-initargs ,@initargs
          :mode ',major-mode)))
     (register-language-spec ',major-mode (make-instance ',spec-name))))

#|
(define-language-spec (js-spec lem-js-mode:js-mode)
  :language-id "javascript"
  :root-uri-patterns '("package.json" "tsconfig.json")
  :command '("typescript-language-server" "--stdio")
  :install-command "npm install -g typescript-language-server typescript"
  :readme-url "https://github.com/typescript-language-server/typescript-language-server"
  :connection-mode :stdio)

(define-language-spec (rust-spec lem-rust-mode:rust-mode)
  :language-id "rust"
  :root-uri-patterns '("Cargo.toml")
  :command '("rls")
  :readme-url "https://github.com/rust-lang/rls"
  :connection-mode :stdio)

(define-language-spec (sql-spec lem-sql-mode:sql-mode)
  :language-id "sql"
  :root-uri-patterns '()
  :command '("sql-language-server" "up" "--method" "stdio")
  :readme-url "https://github.com/joe-re/sql-language-server"
  :connection-mode :stdio)

(defun find-dart-bin-path ()
  (multiple-value-bind (output error-output status)
      (uiop:run-program '("which" "dart")
                        :output :string
                        :ignore-error-status t)
    (declare (ignore error-output))
    (if (zerop status)
        (namestring
         (uiop:pathname-directory-pathname
          (string-right-trim '(#\newline) output)))
        nil)))

(defun find-dart-language-server ()
  (let ((program-name "analysis_server.dart.snapshot"))
    (when-let (path (find-dart-bin-path))
      (let ((result
              (string-right-trim
               '(#\newline)
               (uiop:run-program (list "find" path "-name" program-name)
                                 :output :string))))
        (when (search program-name result)
          result)))))

(define-language-spec (dart-spec lem-dart-mode:dart-mode)
  :language-id "dart"
  :root-uri-patterns '("pubspec.yaml")
  :connection-mode :stdio)

(defmethod spec-command ((spec dart-spec))
  (if-let ((lsp-path (find-dart-language-server)))
    (list "dart" lsp-path "--lsp")
    (editor-error "dart language server not found")))

(defmethod spec-initialization-options ((spec dart-spec))
  (make-lsp-map "onlyAnalyzeProjectsWithOpenFiles" +true+
                "suggestFromUnimportedLibraries" +true+))
|#

#|
Language Features
- [X] completion
- [ ] completion resolve
- [X] hover
- [X] signatureHelp
- [ ] declaration
- [X] definition
- [X] typeDefinition
- [X] implementation
- [X] references
- [X] documentHighlight
- [X] documentSymbol
- [X] codeAction
- [ ] codeLens
- [ ] codeLens resolve
- [ ] documentLink
- [ ] documentLink resolve
- [ ] documentColor
- [ ] colorPresentation
- [X] formatting
- [X] rangeFormatting
- [X] onTypeFormatting
- [X] rename
- [ ] prepareRename
- [ ] foldingRange
- [ ] selectionRange

TODO
- partialResult
- workDoneProgress
|#
