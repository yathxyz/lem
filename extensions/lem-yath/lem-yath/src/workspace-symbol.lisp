;;;; Consult-Eglot-style incremental workspace symbol navigation.

(in-package :lem-yath)

(defparameter *workspace-symbol-minimum-input* 3
  "Minimum query length, matching Consult's async default.")

(defparameter *workspace-symbol-debounce-milliseconds* 200
  "Quiet interval before an incremental workspace/symbol request.")

(defparameter *workspace-symbol-throttle-milliseconds* 500
  "Minimum interval between incremental workspace/symbol requests.")

(defparameter *workspace-symbol-timeout* 10
  "Seconds before one workspace/symbol request times out.")

(defparameter *workspace-symbol-narrow-kinds*
  `((#\c "Class" ,lsp:symbol-kind-class)
    (#\f "Function" ,lsp:symbol-kind-function)
    (#\e "Enum" ,lsp:symbol-kind-enum)
    (#\i "Interface" ,lsp:symbol-kind-interface)
    (#\m "Module" ,lsp:symbol-kind-module)
    (#\n "Namespace" ,lsp:symbol-kind-namespace)
    (#\p "Package" ,lsp:symbol-kind-package)
    (#\s "Struct" ,lsp:symbol-kind-struct)
    (#\t "Type Parameter" ,lsp:symbol-kind-type-parameter)
    (#\v "Variable" ,lsp:symbol-kind-variable)
    (#\A "Array" ,lsp:symbol-kind-array)
    (#\B "Boolean" ,lsp:symbol-kind-boolean)
    (#\C "Constant" ,lsp:symbol-kind-constant)
    (#\E "Enum Member" ,lsp:symbol-kind-enum-member)
    (#\F "Field" ,lsp:symbol-kind-field)
    (#\M "Method" ,lsp:symbol-kind-method)
    (#\N "Number" ,lsp:symbol-kind-number)
    (#\O "Object" ,lsp:symbol-kind-object)
    (#\P "Property" ,lsp:symbol-kind-property)
    (#\S "String" ,lsp:symbol-kind-string)
    (#\o "Other"))
  "Pinned Consult-Eglot narrowing keys, labels, and LSP symbol kinds.")

(defstruct (workspace-symbol-candidate
            (:constructor %make-workspace-symbol-candidate))
  workspace
  symbol
  label
  detail
  filter-text
  group
  narrow-key
  (score 0))

(defstruct workspace-symbol-pending-request
  workspace
  request)

(defstruct workspace-symbol-session
  workspaces
  project-root
  origin-window
  origin-buffer
  origin-point
  origin-view-point
  origin-horizontal-scroll-start
  origin-state
  prompt-window
  query
  candidates
  narrow-key
  selected
  preview-candidate
  preview-buffers
  timer
  requests
  (generation 0)
  last-request-start
  active-p)

(defvar *workspace-symbol-session* nil)

(defparameter *workspace-symbol-prompt-keymap*
  (let ((keymap (make-keymap :description "Workspace symbol prompt")))
    (define-key keymap "C-g" 'lem/prompt-window::prompt-quit)
    (define-key keymap "Escape" 'lem/prompt-window::prompt-quit)
    (define-key keymap "M-p" 'workspace-symbol-prompt-previous-history)
    (define-key keymap "M-n" 'workspace-symbol-prompt-next-history)
    (define-key keymap "Space" 'workspace-symbol-prompt-space)
    (define-key keymap 'delete-previous-char
      'workspace-symbol-prompt-delete-previous-char)
    (define-key keymap "Backspace"
      'workspace-symbol-prompt-delete-previous-char)
    (define-key keymap "C-h" 'workspace-symbol-prompt-delete-previous-char)
    keymap))

(defun workspace-symbol-provider-p (workspace)
  (handler-case
      (not (null
            (lsp:server-capabilities-workspace-symbol-provider
             (lem-lsp-mode::workspace-server-capabilities workspace))))
    (unbound-slot () nil)))

(defun workspace-symbol-location (symbol)
  (typecase symbol
    (lsp:symbol-information
     (lsp:symbol-information-location symbol))
    (lsp:workspace-symbol
     (lsp:workspace-symbol-location symbol))))

(defun workspace-symbol-container (symbol)
  (handler-case (lsp:base-symbol-information-container-name symbol)
    (unbound-slot () nil)))

(defun workspace-symbol-kind-name (symbol)
  (or (nth-value
       0
       (lem-lsp-mode::symbol-kind-to-string-and-attribute
        (lsp:base-symbol-information-kind symbol)))
      "Symbol"))

(defun workspace-symbol-score (symbol)
  "Return Consult-Eglot's optional server ranking score for SYMBOL."
  (handler-case
      (or (lsp:base-symbol-information-score symbol) 0)
    (unbound-slot () 0)))

(defun workspace-symbol-kind-narrow-key (symbol)
  "Return Consult-Eglot's narrowing key for SYMBOL's LSP kind."
  (let ((kind (lsp:base-symbol-information-kind symbol)))
    (or (loop :for entry :in *workspace-symbol-narrow-kinds*
              :for key = (first entry)
              :for mapped-kind = (third entry)
              :when (and mapped-kind
                         (numberp kind)
                         (= kind mapped-kind))
                :return key)
        #\o)))

(defun workspace-symbol-location-pathname (symbol)
  (alexandria:when-let ((location (workspace-symbol-location symbol)))
    (when (typep location 'lsp:location)
      (ignore-errors
        (lem-lsp-base/utils:uri-to-pathname
         (lsp:location-uri location))))))

(defun workspace-symbol-location-summary (workspace symbol &optional project-root)
  (let ((location (workspace-symbol-location symbol)))
    (when (typep location 'lsp:location)
      (let* ((file (workspace-symbol-location-pathname symbol))
             (root (or project-root
                       (lem-lsp-mode::workspace-root-pathname workspace)))
             (range (lsp:location-range location))
             (line (1+ (lsp:position-line (lsp:range-start range)))))
        (when file
          (format nil "~a:~d"
                  (or (and root
                           (ignore-errors (enough-namestring file root)))
                      (namestring file))
                  line))))))

(defun workspace-symbol-to-candidate (workspace symbol &optional project-root)
  (let* ((name (lsp:base-symbol-information-name symbol))
         (kind (workspace-symbol-kind-name symbol))
         (container (workspace-symbol-container symbol))
         (location
           (workspace-symbol-location-summary workspace symbol project-root))
         (detail (format nil "[~a]~@[ ~a~]~@[ — ~a~]"
                         kind container location)))
    (%make-workspace-symbol-candidate
     :workspace workspace
     :symbol symbol
     :label name
     :detail detail
     :filter-text (format nil "~a ~a~@[ ~a~]~@[ ~a~]"
                          name kind container location)
     :group kind
     :narrow-key (workspace-symbol-kind-narrow-key symbol)
     :score (workspace-symbol-score symbol))))

(defun workspace-symbol-response-candidates
    (workspace response &optional project-root)
  (unless (lem-lsp-base/type:lsp-null-p response)
    (map 'list
         (lambda (symbol)
           (workspace-symbol-to-candidate workspace symbol project-root))
         response)))

(defun workspace-symbol-session-restorable-p (session)
  (and (project-picker-live-window-p
        (workspace-symbol-session-origin-window session))
       (project-picker-live-buffer-p
        (workspace-symbol-session-origin-buffer session))
       (alive-point-p (workspace-symbol-session-origin-point session))
       (alive-point-p (workspace-symbol-session-origin-view-point session))))

(defun workspace-symbol-restore-origin (session)
  "Restore the exact buffer, point, viewport, and horizontal scroll."
  (when (workspace-symbol-session-restorable-p session)
    (let ((window (workspace-symbol-session-origin-window session))
          (buffer (workspace-symbol-session-origin-buffer session)))
      (with-current-window window
        (unless (eq (current-buffer) buffer)
          (lem-core::%switch-to-buffer buffer nil nil))
        (move-point (buffer-point buffer)
                    (workspace-symbol-session-origin-point session))
        (move-point (window-view-point window)
                    (workspace-symbol-session-origin-view-point session))
        (setf (window-parameter window 'lem-core::horizontal-scroll-start)
              (workspace-symbol-session-origin-horizontal-scroll-start
               session))))))

(defun workspace-symbol-restore-origin-state (session)
  (let ((window (workspace-symbol-session-origin-window session))
        (state (workspace-symbol-session-origin-state session)))
    (when (and state
               (project-picker-live-window-p window)
               (eq (current-window) window))
      (setf (lem-vi-mode/core:current-state) state))))

(defun workspace-symbol-delete-origin-points (session)
  (dolist (point (list (workspace-symbol-session-origin-point session)
                       (workspace-symbol-session-origin-view-point session)))
    (when point
      (ignore-errors (delete-point point))))
  (setf (workspace-symbol-session-origin-point session) nil
        (workspace-symbol-session-origin-view-point session) nil))

(defun workspace-symbol-track-preview-buffer (session buffer created-p)
  (when created-p
    (pushnew buffer
             (workspace-symbol-session-preview-buffers session)
             :test #'eq))
  buffer)

(defun workspace-symbol-candidate-buffer (candidate)
  (alexandria:when-let
      ((pathname
        (workspace-symbol-location-pathname
         (workspace-symbol-candidate-symbol candidate))))
    (project-picker-open-file-buffer pathname)))

(defun workspace-symbol-delete-preview-buffers (session &optional keep)
  (dolist (buffer (workspace-symbol-session-preview-buffers session))
    (when (and (project-picker-live-buffer-p buffer)
               (not (eq buffer keep))
               (not (buffer-modified-p buffer))
               (null (get-buffer-windows buffer)))
      (ignore-errors (delete-buffer buffer))))
  (setf (workspace-symbol-session-preview-buffers session) nil))

(defun workspace-symbol-clear-preview (session)
  (when (workspace-symbol-session-preview-candidate session)
    (workspace-symbol-restore-origin session)
    (setf (workspace-symbol-session-preview-candidate session) nil)))

(defun workspace-symbol-preview (session candidate)
  "Preview CANDIDATE without recording a buffer-history or jump entry."
  (when (and (workspace-symbol-session-active-p session)
             (not (eq candidate
                      (workspace-symbol-session-preview-candidate session))))
    (handler-case
        (progn
          (workspace-symbol-clear-preview session)
          (let* ((symbol (workspace-symbol-candidate-symbol candidate))
                 (location (workspace-symbol-location symbol))
                 (pathname (workspace-symbol-location-pathname symbol)))
            (when (and (typep location 'lsp:location)
                       pathname
                       (uiop:file-exists-p pathname)
                       (workspace-symbol-session-restorable-p session))
              (multiple-value-bind (buffer created-p)
                  (find-file-buffer pathname)
                (workspace-symbol-track-preview-buffer
                 session buffer created-p)
                (with-current-window
                    (workspace-symbol-session-origin-window session)
                  (lem-core::%switch-to-buffer buffer nil t)
                  (unless (lem-lsp-mode::move-to-workspace-position
                           (buffer-point buffer)
                           (lsp:range-start (lsp:location-range location))
                           (workspace-symbol-candidate-workspace candidate))
                    (error "Invalid workspace-symbol position"))
                  (window-recenter (current-window)))
                (setf (workspace-symbol-session-preview-candidate session)
                      candidate)))))
      (error ()
        (ignore-errors (workspace-symbol-restore-origin session))
        (setf (workspace-symbol-session-preview-candidate session) nil)))))

(defun workspace-symbol-completion-item (session candidate input)
  (with-point ((start (lem/prompt-window::current-prompt-start-point))
               (end (lem/prompt-window::current-prompt-start-point)))
    (let ((candidate candidate))
      (lem/completion-mode:make-completion-item
       :label (workspace-symbol-candidate-label candidate)
       :insert-text input
       :detail (workspace-symbol-candidate-detail candidate)
       :filter-text (workspace-symbol-candidate-filter-text candidate)
       :group (workspace-symbol-candidate-group candidate)
       :start start
       :end (line-end end)
       :focus-action
       (lambda (context)
         (declare (ignore context))
         (workspace-symbol-preview session candidate))
       :accept-action
       (lambda ()
         (setf (workspace-symbol-session-selected session) candidate))))))

(defun workspace-symbol-completion-items (session input)
  (let* ((narrow-key (workspace-symbol-session-narrow-key session))
         (candidates
           (if narrow-key
               (remove-if-not
                (lambda (candidate)
                  (char= narrow-key
                         (workspace-symbol-candidate-narrow-key candidate)))
                (workspace-symbol-session-candidates session))
               (workspace-symbol-session-candidates session))))
    (mapcar
     (lambda (candidate)
       (workspace-symbol-completion-item session candidate input))
     (prescient-filter
      input candidates
      :key #'workspace-symbol-candidate-filter-text
      :category :workspace-symbol
      :rank-p nil))))

(defun workspace-symbol-completion-observer (session event item)
  (case event
    (:present
     (unless item
       (workspace-symbol-clear-preview session)))
    (:end
     (workspace-symbol-clear-preview session))))

(defun workspace-symbol-install-completion-options (session)
  (setf
   (workspace-symbol-session-prompt-window session)
   (lem/prompt-window:current-prompt-window)
   (variable-value
    'lem/completion-mode:completion-context-options-function
    :buffer (current-buffer))
   (lambda (spec)
     (declare (ignore spec))
     (list
      :narrowing nil
      :observer-function
      (lambda (context event item)
        (declare (ignore context))
        (workspace-symbol-completion-observer session event item))))))

(defun workspace-symbol-prompt-active-p (session)
  (and (workspace-symbol-session-active-p session)
       (workspace-symbol-session-prompt-window session)
       (eq (workspace-symbol-session-prompt-window session)
           (ignore-errors (lem/prompt-window:current-prompt-window)))))

(defun workspace-symbol-refresh-completion (session)
  (when (workspace-symbol-session-active-p session)
    ;; A focused candidate previews in the origin window.  Async responses
    ;; arriving after that preview therefore run with a source buffer current,
    ;; while prompt completion must be created with the prompt buffer current.
    (with-current-window (workspace-symbol-session-prompt-window session)
      (cond
        (lem/completion-mode::*completion-context*
         (lem/completion-mode:completion-refresh))
        ((workspace-symbol-session-candidates session)
         (lem/prompt-window::open-prompt-completion))))))

(defun workspace-symbol-stop-timer (session)
  (alexandria:when-let ((timer (workspace-symbol-session-timer session)))
    (unless (timer-expired-p timer)
      (stop-timer timer))
    (setf (workspace-symbol-session-timer session) nil)))

(defun workspace-symbol-cancel-pending-request (pending)
  "Forget PENDING's callback and notify its source workspace."
  (alexandria:when-let
      ((request (workspace-symbol-pending-request-request pending)))
    (handler-case
        (let* ((client
                 (lem-lsp-mode::workspace-client
                  (workspace-symbol-pending-request-workspace pending)))
               (id (jsonrpc:request-id request))
               (jsonrpc-client
                 (lem-language-client/client:client-connection client))
               (connection
                 (jsonrpc::transport-connection
                  (jsonrpc::jsonrpc-transport jsonrpc-client))))
          (jsonrpc/connection:remove-callback-for-id connection id)
          (lem-language-client/request:request
           client
           (make-instance 'lsp:/cancel-request)
           (make-instance 'lsp:cancel-params :id id)))
      (error (condition)
        (log:warn "Could not cancel workspace-symbol request: ~A"
                  condition)))))

(defun workspace-symbol-cancel-requests (session)
  "Invalidate and cancel every live request belonging to SESSION."
  (let ((requests (workspace-symbol-session-requests session)))
    (setf (workspace-symbol-session-requests session) nil)
    (dolist (request requests)
      (workspace-symbol-cancel-pending-request request))))

(defun workspace-symbol-current-request-p
    (session generation query pending)
  (and (workspace-symbol-session-active-p session)
       (= generation (workspace-symbol-session-generation session))
       (string= query (or (workspace-symbol-session-query session) ""))
       (member pending (workspace-symbol-session-requests session)
               :test #'eq)))

(defun workspace-symbol-finish-response
    (session generation query pending response)
  (when (workspace-symbol-current-request-p
         session generation query pending)
    (let ((candidates
            (handler-case
                (workspace-symbol-response-candidates
                 (workspace-symbol-pending-request-workspace pending)
                 response
                 (workspace-symbol-session-project-root session))
              (error (condition)
                (workspace-symbol-finish-error
                 session generation query pending
                 (princ-to-string condition) nil)
                (return-from workspace-symbol-finish-response nil)))))
      (setf (workspace-symbol-session-requests session)
            (delete pending
                    (workspace-symbol-session-requests session)
                    :test #'eq)
            (workspace-symbol-session-candidates session)
            (stable-sort
             (append (workspace-symbol-session-candidates session)
                     candidates)
             #'>
             :key #'workspace-symbol-candidate-score))
      (workspace-symbol-refresh-completion session))))

(defun workspace-symbol-finish-error
    (session generation query pending message code)
  (when (workspace-symbol-current-request-p
         session generation query pending)
    (setf (workspace-symbol-session-requests session)
          (delete pending
                  (workspace-symbol-session-requests session)
                  :test #'eq))
    (workspace-symbol-refresh-completion session)
    (message "Workspace symbol search failed: ~a~@[ (code ~a)~]"
             message code)))

(defun workspace-symbol-start-workspace-request
    (session generation query workspace)
  (let ((pending
          (make-workspace-symbol-pending-request :workspace workspace))
        (jsonrpc:*default-timeout* *workspace-symbol-timeout*))
    (push pending (workspace-symbol-session-requests session))
    (handler-case
        (setf (workspace-symbol-pending-request-request pending)
              (lem-language-client/request:request-async
               (lem-lsp-mode::workspace-client workspace)
               (make-instance 'lsp:workspace/symbol)
               (make-instance 'lsp:workspace-symbol-params :query query)
               (lambda (response)
                 (send-event
                  (lambda ()
                    (workspace-symbol-finish-response
                     session generation query pending response))))
               (lambda (message code)
                 (send-event
                  (lambda ()
                    (workspace-symbol-finish-error
                     session generation query pending message code))))))
      (error (condition)
        (workspace-symbol-finish-error
         session generation query pending
         (princ-to-string condition) nil)))))

(defun workspace-symbol-start-requests (session generation query)
  (when (and (workspace-symbol-prompt-active-p session)
             (= generation (workspace-symbol-session-generation session))
             (string= query (workspace-symbol-session-query session)))
    (setf (workspace-symbol-session-timer session) nil
          (workspace-symbol-session-last-request-start session)
          (get-internal-real-time))
    (dolist (workspace (workspace-symbol-session-workspaces session))
      (workspace-symbol-start-workspace-request
       session generation query workspace))))

(defun workspace-symbol-next-delay (session)
  (let ((last (workspace-symbol-session-last-request-start session)))
    (if (null last)
        *workspace-symbol-debounce-milliseconds*
        (let* ((elapsed
                 (floor
                  (* 1000
                     (/ (- (get-internal-real-time) last)
                        internal-time-units-per-second))))
               (throttle-remaining
                 (max 0
                      (- *workspace-symbol-throttle-milliseconds*
                         elapsed))))
          (max *workspace-symbol-debounce-milliseconds*
               throttle-remaining)))))

(defun workspace-symbol-schedule-query (session input)
  (unless (or (workspace-symbol-session-selected session)
              (string= input
                       (or (workspace-symbol-session-query session) "")))
    (incf (workspace-symbol-session-generation session))
    (workspace-symbol-stop-timer session)
    (workspace-symbol-cancel-requests session)
    (setf (workspace-symbol-session-query session) input
          (workspace-symbol-session-candidates session) nil)
    (workspace-symbol-clear-preview session)
    (when lem/completion-mode::*completion-context*
      (lem/completion-mode:completion-end))
    (when (>= (length input) *workspace-symbol-minimum-input*)
      (let ((generation (workspace-symbol-session-generation session))
            (query (copy-seq input)))
        (setf (workspace-symbol-session-timer session)
              (start-timer
               (make-timer
                (lambda ()
                  (workspace-symbol-start-requests
                   session generation query))
                :name "workspace-symbol-debounce")
               (workspace-symbol-next-delay session)))))))

(defun workspace-symbol-narrow-key-for-input (input)
  (and (= (length input) 1)
       (alexandria:when-let
           ((entry (assoc (char input 0)
                          *workspace-symbol-narrow-kinds*
                          :test #'char=)))
         (first entry))))

(defun workspace-symbol-narrow-label (key)
  (second (assoc key *workspace-symbol-narrow-kinds* :test #'char=)))

(defun workspace-symbol-prompt-prefix (session)
  (alexandria:if-let
      ((key (workspace-symbol-session-narrow-key session)))
    (format nil "LSP Symbols: [~a] "
            (workspace-symbol-narrow-label key))
    "LSP Symbols: "))

(defun workspace-symbol-reset-prompt-prefix (session)
  "Replace the prompt indicator and clear its input without ending SESSION."
  (lem/completion-mode:completion-end)
  (let* ((prompt (lem/prompt-window:current-prompt-window))
         (buffer (window-buffer prompt)))
    (setf (slot-value buffer 'lem/prompt-window::prompt-string)
          (workspace-symbol-prompt-prefix session))
    (lem/prompt-window::initialize-prompt-buffer buffer)
    (lem/prompt-window::initialize-prompt prompt)
    (lem/prompt-window::update-prompt-window prompt)
    (lem/prompt-window::open-prompt-completion)))

(define-command workspace-symbol-prompt-space () ()
  "Narrow on a pinned kind key plus Space; otherwise insert query Space."
  (let* ((session *workspace-symbol-session*)
         (input (lem/prompt-window::get-input-string))
         (narrow-key
           (and session (workspace-symbol-narrow-key-for-input input))))
    (if narrow-key
        (progn
          (setf (workspace-symbol-session-narrow-key session) narrow-key)
          (workspace-symbol-schedule-query session "")
          (workspace-symbol-reset-prompt-prefix session))
        (progn
          (insert-character (current-point) #\Space)
          (when session
            (workspace-symbol-schedule-query
             session (lem/prompt-window::get-input-string)))))))

(define-command workspace-symbol-prompt-delete-previous-char () ()
  "Widen an empty narrowed prompt; otherwise delete one query character."
  (let ((session *workspace-symbol-session*))
    (if (and session
             (workspace-symbol-session-narrow-key session)
             (zerop (length (lem/prompt-window::get-input-string))))
        (progn
          (setf (workspace-symbol-session-narrow-key session) nil)
          (workspace-symbol-reset-prompt-prefix session))
        (progn
          (when (point> (current-point)
                        (lem/prompt-window::current-prompt-start-point))
            (delete-previous-char 1))
          (when session
            (workspace-symbol-schedule-query
             session (lem/prompt-window::get-input-string)))))))

(define-command workspace-symbol-prompt-previous-history () ()
  "Move backward through workspace-symbol query history and refresh it."
  (lem/prompt-window::prompt-previous-history)
  (when *workspace-symbol-session*
    (workspace-symbol-schedule-query
     *workspace-symbol-session*
     (lem/prompt-window::get-input-string))))

(define-command workspace-symbol-prompt-next-history () ()
  "Move forward through workspace-symbol query history and refresh it."
  (lem/prompt-window::prompt-next-history)
  (when *workspace-symbol-session*
    (workspace-symbol-schedule-query
     *workspace-symbol-session*
     (lem/prompt-window::get-input-string))))

(defun workspace-symbol-read-candidate (session)
  (let ((*workspace-symbol-session* session)
        (*prompt-after-activate-hook*
          (cons (cons (lambda ()
                        (workspace-symbol-install-completion-options session))
                      0)
                *prompt-after-activate-hook*)))
    (prompt-for-string
     "LSP Symbols: "
     :completion-function
     (lambda (input)
       (workspace-symbol-completion-items session input))
     :test-function
     (lambda (input)
       (and (workspace-symbol-session-selected session)
            (string= input (workspace-symbol-session-query session))))
     :edit-callback
     (lambda (input)
       (workspace-symbol-schedule-query session input))
     :history-symbol 'lem-yath-workspace-symbol
     :special-keymap *workspace-symbol-prompt-keymap*))
  (workspace-symbol-session-selected session))

(defun goto-workspace-symbol (candidate)
  (let* ((symbol (workspace-symbol-candidate-symbol candidate))
         (workspace (workspace-symbol-candidate-workspace candidate))
         (location (workspace-symbol-location symbol)))
    (unless (typep location 'lsp:location)
      (editor-error
       "The language server returned a workspace symbol without a location."))
    (let ((xref (lem-lsp-mode::convert-location location workspace)))
      (unless xref
        (editor-error
         "The workspace symbol location is not a readable local file."))
      (lem/language-mode::push-location-stack (current-point))
      (lem-vi-mode/jumplist:with-jumplist
        (lem/language-mode:go-to-location xref #'switch-to-buffer))
      (jump-feedback-after-jump))))

(defun workspace-symbol-buffer-project-root (buffer)
  (when (and (project-picker-live-buffer-p buffer)
             (buffer-filename buffer))
    (ignore-errors
      (lem-yath-project-root-for-directory (buffer-directory buffer)))))

(defun workspace-symbol-workspace-in-project-p (workspace project-root)
  (some (lambda (buffer)
          (alexandria:when-let
              ((root (workspace-symbol-buffer-project-root buffer)))
            (uiop:pathname-equal root project-root)))
        (lem-lsp-mode::workspace-buffers workspace)))

(defun workspace-symbol-eligible-workspace-p (workspace)
  (and (eq :ready (lem-lsp-mode::workspace-state workspace))
       (workspace-symbol-provider-p workspace)))

(defun workspace-symbol-project-workspaces (primary)
  "Return Consult-Eglot-style symbol providers for PRIMARY's project.

When the invoking buffer has no recognized project, retain the native Eglot
fallback of querying only the current server."
  (let ((project-root
          (workspace-symbol-buffer-project-root (current-buffer))))
    (values
     (if project-root
         (let ((workspaces
                 (remove-if-not
                  (lambda (workspace)
                    (and (workspace-symbol-eligible-workspace-p workspace)
                         (workspace-symbol-workspace-in-project-p
                          workspace project-root)))
                  (lem-lsp-mode::all-workspaces))))
           (when (member primary workspaces :test #'eq)
             (setf workspaces
                   (cons primary (delete primary workspaces :test #'eq))))
           workspaces)
         (and (workspace-symbol-eligible-workspace-p primary)
              (list primary)))
     project-root)))

(defun workspace-symbol-make-session (workspaces project-root)
  (let ((window (current-window))
        (buffer (current-buffer)))
    (make-workspace-symbol-session
     :workspaces workspaces
     :project-root project-root
     :origin-window window
     :origin-buffer buffer
     :origin-point (copy-point (buffer-point buffer) :right-inserting)
     :origin-view-point
     (copy-point (window-view-point window) :right-inserting)
     :origin-horizontal-scroll-start
     (window-parameter window 'lem-core::horizontal-scroll-start)
     :origin-state (ignore-errors (lem-vi-mode/core:current-state))
     :query ""
     :active-p t)))

(defun workspace-symbol-cleanup (session committed-candidate)
  (setf (workspace-symbol-session-active-p session) nil)
  (incf (workspace-symbol-session-generation session))
  (workspace-symbol-stop-timer session)
  (workspace-symbol-cancel-requests session)
  (unless committed-candidate
    (workspace-symbol-restore-origin session))
  (workspace-symbol-delete-preview-buffers
   session
   (and committed-candidate
        (workspace-symbol-candidate-buffer committed-candidate)))
  (workspace-symbol-restore-origin-state session)
  (workspace-symbol-delete-origin-points session))

(define-command lem-yath-workspace-symbol () ()
  "Incrementally query every symbol server in the current project."
  (handler-case
      (let ((workspace (lem-lsp-mode::check-connection)))
        (multiple-value-bind (workspaces project-root)
            (workspace-symbol-project-workspaces workspace)
          (unless workspaces
            (editor-error
             "No language server in this project provides workspace symbols."))
          (let ((session
                  (workspace-symbol-make-session
                   workspaces project-root))
                (committed nil))
            (unwind-protect
                 (alexandria:when-let
                     ((candidate (workspace-symbol-read-candidate session)))
                   (workspace-symbol-restore-origin session)
                   (workspace-symbol-clear-preview session)
                   (workspace-symbol-delete-preview-buffers
                    session (workspace-symbol-candidate-buffer candidate))
                   (with-current-window
                       (workspace-symbol-session-origin-window session)
                     (goto-workspace-symbol candidate))
                   (setf committed candidate))
              (workspace-symbol-cleanup session committed)))))
    (editor-abort () nil)
    (error (condition)
      (message "Workspace symbol search failed: ~a" condition))))
