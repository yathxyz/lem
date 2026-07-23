(in-package :lem-yath)

(defvar *llm-workflow-report* (uiop:getenv "LEM_YATH_LLM_WORKFLOW_REPORT"))
(defvar *llm-workflow-source-buffer* (current-buffer))
(defvar *llm-workflow-context-prompt* nil)
(defvar *llm-workflow-context-visible-prompt* nil)
(defvar *llm-workflow-context-messages* nil)
(defvar *llm-workflow-capture-prompt* nil)
(defvar *llm-workflow-capture-buffer* nil)
(defvar *llm-workflow-routing-dispatches* 0)
(defvar *llm-workflow-routing-prompt* nil)
(defvar *llm-workflow-routing-messages* nil)
(defvar *llm-workflow-rewrite-dispatches* 0)
(defvar *llm-workflow-rewrite-prompt* nil)
(defvar *llm-workflow-rewrite-system* nil)
(defvar *llm-workflow-variant-dispatches* 0)
(defvar *llm-workflow-variant-prompt* nil)
(defvar *llm-workflow-variant-messages* nil)
(defvar *llm-workflow-variant-settings* nil)
(defparameter *llm-workflow-routing-target-name* "*llm-route-target*")
(defparameter *llm-workflow-routing-session-name* "*llm-route-session*")

(defmethod llm-backend-stream
    ((backend (eql :lem-yath-context-test)) prompt)
  (declare (ignore backend))
  (setf *llm-workflow-context-prompt* prompt
        *llm-workflow-context-visible-prompt* (llm-visible-prompt prompt)
        *llm-workflow-context-messages* *llm-conversation-messages*))

(defmethod llm-backend-stream
    ((backend (eql :lem-yath-capture-test)) prompt)
  (declare (ignore backend))
  (let* ((buffer (llm-output-buffer))
         (insertion-point
           (llm-prepare-response buffer "UNEXPECTED-SHARED-CAPTURE"))
         (request
           (llm-register-request
            buffer nil :lem-yath-capture-test
            :prompt (llm-visible-prompt prompt)
            :insertion-point insertion-point)))
    (setf *llm-workflow-capture-prompt* prompt
          *llm-workflow-capture-buffer* buffer)
    (llm-request-complete-now
     request (format nil "CAPTURE-RESPONSE-SENTINEL~%"))))

(defmethod llm-backend-stream
    ((backend (eql :lem-yath-routing-test)) prompt)
  (declare (ignore backend))
  (let* ((buffer (llm-output-buffer))
         (insertion-point
           (llm-prepare-response buffer "UNEXPECTED-SHARED-ROUTING"))
         (request
           (llm-register-request
            buffer nil :lem-yath-routing-test
            :prompt (llm-visible-prompt prompt)
            :insertion-point insertion-point)))
    (incf *llm-workflow-routing-dispatches*)
    (setf *llm-workflow-routing-prompt* prompt
          *llm-workflow-routing-messages* *llm-conversation-messages*)
    (llm-request-complete-now request "ROUTED-RESPONSE-SENTINEL")))

(defmethod llm-backend-stream
    ((backend (eql :lem-yath-rewrite-test)) prompt)
  (declare (ignore backend))
  (let* ((buffer (llm-output-buffer))
         (insertion-point
           (llm-prepare-response buffer "UNEXPECTED-SHARED-REWRITE"))
         (request
           (llm-register-request
            buffer nil :lem-yath-rewrite-test
            :prompt (llm-visible-prompt prompt)
            :insertion-point insertion-point))
         (response
           (case (incf *llm-workflow-rewrite-dispatches*)
             (1 "REWRITTEN")
             (2 "ITERATED")
             (otherwise "REJECTED"))))
    (setf *llm-workflow-rewrite-prompt* prompt
          *llm-workflow-rewrite-system* *llm-system-message*)
    (llm-request-complete-now request response)))

(defmethod llm-backend-stream
    ((backend (eql :lem-yath-variant-test)) prompt)
  (let* ((buffer (llm-output-buffer))
         (insertion-point
           (llm-prepare-response buffer "UNEXPECTED-SHARED-VARIANT"))
         (request
           (llm-register-request
            buffer nil backend
            :prompt (llm-visible-prompt prompt)
            :insertion-point insertion-point)))
    (incf *llm-workflow-variant-dispatches*)
    (setf *llm-workflow-variant-prompt* prompt
          *llm-workflow-variant-messages* *llm-conversation-messages*
          *llm-workflow-variant-settings*
          (list *llm-backend* *llm-model* *llm-system-message*
                *llm-temperature* *llm-max-tokens* *llm-use-tools*))
    (llm-request-complete-now request "VARIANT-TWO")))

(defmethod llm-backend-stream
    ((backend (eql :lem-yath-variant-fail-test)) prompt)
  (incf *llm-workflow-variant-dispatches*)
  (setf *llm-workflow-variant-prompt* prompt
        *llm-workflow-variant-messages* *llm-conversation-messages*
        *llm-workflow-variant-settings*
        (list backend *llm-model* *llm-system-message*
              *llm-temperature* *llm-max-tokens* *llm-use-tools*))
  (message "Fixture backend declined to launch"))

(setf *llm-handoff-browser-commands*
      (list (uiop:getenv "LEM_YATH_LLM_WORKFLOW_BROWSER"))
      *llm-handoff-browser-arguments* '("--new-window"))

(defun llm-workflow-log (control &rest arguments)
  (with-open-file (stream *llm-workflow-report*
                          :direction :output
                          :if-exists :append
                          :if-does-not-exist :create)
    (apply #'format stream control arguments)
    (terpri stream)))

(defun llm-workflow-mode-bits (pathname)
  #+sbcl
  (format nil "~3,'0o"
          (logand (sb-posix:stat-mode
                   (sb-posix:stat (uiop:native-namestring pathname)))
                  #o777))
  #-sbcl "unsupported")

(defun llm-workflow-uuid-v4-p (value)
  (and (stringp value)
       (= (length value) 36)
       (loop :for index :in '(8 13 18 23)
             :always (char= (char value index) #\-))
       (char= (char value 14) #\4)
       (find (char-downcase (char value 19)) "89ab" :test #'char=)
       (loop :for index :below 36
             :always
             (or (member index '(8 13 18 23))
                 (digit-char-p (char value index) 16)))))

(defun llm-workflow-killring-head ()
  (or (lem/common/killring:peek-killring-item (current-killring) 0) ""))

(defun llm-workflow-one-line (text)
  (substitute #\| #\Newline (or text "none")))

(define-command lem-yath-test-llm-workflow-static () ()
  (let ((failures 0))
    (labels ((check (condition name)
               (llm-workflow-log "~a STATIC ~a"
                                 (if condition "PASS" "FAIL") name)
               (unless condition (incf failures))))
      (check (and (eq 'lem-yath-llm-menu
                      (leader-binding-command
                       lem-vi-mode:*normal-keymap* "g l"))
                  (eq 'lem-yath-llm-menu
                      (leader-binding-command
                       lem-vi-mode:*visual-keymap* "g l"))
                  (eq 'lem-yath-llm-full-menu
                      (leader-binding-command
                       lem-vi-mode:*normal-keymap* "g L"))
                  (eq 'lem-yath-llm-full-menu
                      (leader-binding-command
                       lem-vi-mode:*visual-keymap* "g L")))
             "compact-and-full-menu-leaders")
      (check (eq 'lem-yath-llm-ask
                 (leader-binding-command lem-vi-mode:*normal-keymap* "g i"))
             "ad-hoc-instruction-retained")
      (check (and (eq 'lem-yath-llm-save-preset (llm-menu-command "s"))
                  (eq 'lem-yath-llm-handoff-claude (llm-menu-command "c"))
                  (eq 'lem-yath-llm-handoff-chatgpt-search
                      (llm-menu-command "w"))
                  (eq 'lem-yath-llm-full-menu (llm-menu-command "m")))
             "compact-menu-dispatch")
      (multiple-value-bind (command reopen-p) (llm-full-menu-action "T")
        (check (and (eq command 'lem-yath-llm-set-temperature) reopen-p)
               "full-menu-setting-dispatch"))
      (multiple-value-bind (command reopen-p) (llm-full-menu-action "j")
        (check (and (eq command 'lem-yath-llm-send) (not reopen-p))
               "full-menu-send-dispatch"))
      (multiple-value-bind (command reopen-p) (llm-full-menu-action "-")
        (check (and (eq command 'lem-yath-llm-context-menu) reopen-p)
               "full-menu-context-dispatch"))
      (check
       (and (eq (nth-value 0 (llm-full-menu-action "e"))
                'lem-yath-llm-response-echo)
            (nth-value 1 (llm-full-menu-action "e"))
            (eq (nth-value 0 (llm-full-menu-action "b"))
                'lem-yath-llm-response-buffer)
            (eq (nth-value 0 (llm-full-menu-action "g"))
                'lem-yath-llm-response-conversation)
            (eq (nth-value 0 (llm-full-menu-action "k"))
                'lem-yath-llm-response-kill-ring)
            (eq (nth-value 0 (llm-full-menu-action "J"))
                'lem-yath-llm-inspect-request-json))
       "gptel-response-and-dry-run-dispatch")
      (multiple-value-bind (command reopen-p) (llm-full-menu-action "r")
        (check (and (eq command 'lem-yath-llm-rewrite) (not reopen-p))
               "gptel-rewrite-dispatch"))
      (check
       (and (eq (nth-value 0 (llm-full-menu-action "Space"))
                'lem-yath-llm-response-mark)
            (eq (nth-value 0 (llm-full-menu-action "M-Return"))
                'lem-yath-llm-response-regenerate)
            (eq (nth-value 0 (llm-full-menu-action "P"))
                'lem-yath-llm-response-previous)
            (eq (nth-value 0 (llm-full-menu-action "N"))
                'lem-yath-llm-response-next)
            (eq (nth-value 0 (llm-full-menu-action "E"))
                'lem-yath-llm-response-diff))
       "gptel-response-variant-dispatch")
      (let ((*llm-response-variant-limit* 2)
            (*llm-response-variant-character-limit* 5))
        (check
         (and (equal (llm-response-bounded-history
                      '("aa" "bb" "cc"))
                     '("aa" "bb"))
              (not (llm-response-variants-supported-p :codex))
              (llm-response-variants-supported-p :openrouter))
         "response-variant-bounds-and-backend-policy"))
      (check (and (eq (llm-context-menu-command "r")
                      'lem-yath-llm-context-add-region)
                  (eq (llm-context-menu-command "b")
                      'lem-yath-llm-context-add-buffer)
                  (eq (llm-context-menu-command "f")
                      'lem-yath-llm-context-add-file)
                  (eq (llm-context-menu-command "d")
                      'lem-yath-llm-context-clear)
                  (eq (llm-context-menu-command "e")
                      'vile-config/add-elisp-to-gptel-context))
             "gptel-context-key-sequences")
      (check (and (null (llm-menu-temperature-value ""))
                  (= (llm-menu-temperature-value "1.25") 1.25d0)
                  (not (llm-menu-temperature-valid-p "2.1"))
                  (null (llm-menu-token-value ""))
                  (= (llm-menu-token-value "2048") 2048)
                  (not (llm-menu-token-valid-p "0")))
             "full-menu-number-validation")
      (check (and (assoc "quick-lookup" *llm-builtin-presets* :test #'string=)
                  (assoc "grok-build" *llm-builtin-presets* :test #'string=))
             "implemented-builtins")
      (let* ((body (yason:parse (llm-request-body "body prompt")))
             (messages (gethash "messages" body)))
        (check (and (string= (gethash "model" body) "openrouter/auto")
                    (= (gethash "temperature" body) 0.2)
                    (= (gethash "max_tokens" body) 800)
                    (string= (gethash "content" (elt messages 0))
                             *llm-system-message*))
               "quick-lookup-request-settings"))
      (let ((*llm-temperature* nil))
        (check (not (nth-value 1
                               (gethash
                                "temperature"
                                (yason:parse
                                 (llm-request-body "default temperature")))))
               "temperature-default-omitted"))
      (let* ((text (concatenate 'string "old" (make-string 14000
                                                            :initial-element #\x)))
             (truncated (llm-handoff-truncate text 13000)))
        (check (and (= (length truncated) 13000)
                    (string= "[Truncated by Lem" truncated
                             :end2 (length "[Truncated by Lem"))
                    (char= (char truncated (1- (length truncated))) #\x))
               "bounded-tail-context"))
      (check (and (not (llm-preset-name-valid-p ""))
                  (not (llm-preset-name-valid-p (format nil "bad~%name"))))
             "reject-invalid-preset-names")
      (let ((other (make-buffer "*llm-context-other*")))
        (unwind-protect
             (progn
               (setf (buffer-value *llm-workflow-source-buffer*
                                   *llm-context-buffer-key*) nil)
               (insert-string (buffer-start-point other)
                              "CONTEXT-TRANSPORT-SENTINEL")
               (llm-context-add-source
                *llm-workflow-source-buffer*
                (make-llm-context-source
                 :kind :region :label "fixture region"
                 :value (points-to-string (buffer-start-point other)
                                          (buffer-end-point other))))
               (erase-buffer other)
               (insert-string (buffer-start-point other)
                              "MUTATED-AFTER-SNAPSHOT")
               (check (and (= (llm-context-count
                               *llm-workflow-source-buffer*) 1)
                           (zerop (llm-context-count other)))
                      "context-is-buffer-local")
               (let* ((messages
                        (list (llm-json-object
                               "role" "user" "content" "visible prompt")))
                      (*llm-backend* :lem-yath-context-test))
                 (setf *llm-workflow-context-prompt* nil
                       *llm-workflow-context-visible-prompt* nil
                       *llm-workflow-context-messages* nil)
                 (llm-dispatch-prompt-from-current-buffer
                  "visible prompt" messages)
                 (check
                  (and (search "visible prompt" *llm-workflow-context-prompt*)
                       (search "Request context:"
                               *llm-workflow-context-prompt*)
                       (search "CONTEXT-TRANSPORT-SENTINEL"
                               *llm-workflow-context-prompt*)
                       (string= *llm-workflow-context-visible-prompt*
                                "visible prompt")
                       (string=
                        (llm-conversation-last-user-content
                         *llm-workflow-context-messages*)
                        *llm-workflow-context-prompt*))
                  "context-transport-hidden-from-transcript"))
               (let ((rendered
                       (llm-context-render *llm-workflow-source-buffer*)))
                 (check (and (search "CONTEXT-TRANSPORT-SENTINEL" rendered)
                             (not (search "MUTATED-AFTER-SNAPSHOT" rendered)))
                        "region-context-snapshot"))
               (let ((root (llm-context-emacs-config-root
                            *llm-workflow-source-buffer*)))
                 (check root "audited-emacs-helper-recognized")
                 (when root
                   (let* ((file (merge-pathnames "early-init.el" root))
                          (original (llm-context-read-file file)))
                     (unwind-protect
                          (progn
                            (setf (buffer-value *llm-workflow-source-buffer*
                                                *llm-context-buffer-key*) nil)
                            (llm-context-add-path
                             *llm-workflow-source-buffer* file)
                            (with-open-file
                                (stream file :direction :output
                                             :if-exists :supersede)
                              (write-line "LIVE-FILE-CONTEXT-SENTINEL" stream))
                            (check
                             (search "LIVE-FILE-CONTEXT-SENTINEL"
                                     (llm-context-render
                                      *llm-workflow-source-buffer*))
                             "file-context-read-live"))
                       (with-open-file
                           (stream file :direction :output
                                        :if-exists :supersede)
                         (write-string original stream))))))
               (setf (buffer-value *llm-workflow-source-buffer*
                                   *llm-context-buffer-key*)
                     (list
                      (make-llm-context-source
                       :kind :region :label "oversized"
                       :value (make-string
                               (1+ *llm-context-total-byte-limit*)
                               :initial-element #\x))))
               (check
                (handler-case
                    (progn
                      (llm-context-render *llm-workflow-source-buffer*) nil)
                  (error () t))
                "context-total-byte-limit")
               (setf (buffer-value *llm-workflow-source-buffer*
                                   *llm-context-buffer-key*) nil))
          (delete-buffer other)))
      (let ((target (make-buffer "*llm-forward-static*"))
            (source *llm-workflow-source-buffer*))
        (unwind-protect
             (let* ((*llm-request-source-buffer* source)
                    (request
                      (llm-register-request
                       target nil :lem-yath-routing-test
                       :prompt "forward-static")))
               (check (and (eq target (llm-forward-request-buffer source))
                           (eq target (llm-current-output-buffer)))
                      "redirected-request-source-lookup")
               (llm-request-complete-now request nil)
               (check (null (llm-forward-request-buffer source))
                      "redirected-request-source-cleanup"))
          (when (member target (buffer-list) :test #'eq)
            (delete-buffer target))))
      (let ((source (make-buffer "*llm-forward-kill-source-static*"))
            (target (make-buffer " *llm-forward-kill-target-static*")))
        (unwind-protect
             (let* ((*llm-request-source-buffer* source)
                    (request
                      (llm-register-request
                       target nil :lem-yath-routing-test
                       :prompt "forward-kill-static")))
               (llm-kill-buffer-hook source)
               (check
                (and (llm-request-aborted-now-p request)
                     (null (llm-active-request target))
                     (null (llm-forward-request-buffer source)))
                "redirected-source-kill-aborts"))
          (dolist (buffer (list source target))
            (when (llm-buffer-live-p buffer)
              (delete-buffer buffer)))))
      (let* ((target (make-buffer " *llm-abort-redirect-static*"
                                  :enable-undo-p nil))
             (source *llm-workflow-source-buffer*)
             (kill-before (llm-workflow-killring-head)))
        (unwind-protect
             (let ((*llm-request-source-buffer* source)
                   (*llm-response-finish-function*
                     (llm-redirect-response-finish-function
                      :kill-ring target :lem-yath-routing-test)))
               (insert-string (buffer-start-point target) "PARTIAL-RESPONSE")
               (let ((request
                       (llm-register-request
                        target nil :lem-yath-routing-test
                        :prompt "abort-redirect")))
                 (llm-request-abort-now request)
                 (llm-request-complete-now request "[request aborted]")
                 (check
                  (and (not (llm-buffer-live-p target))
                       (string= kill-before (llm-workflow-killring-head))
                       (null (llm-forward-request-buffer source)))
                  "redirected-abort-no-copy")))
          (when (llm-buffer-live-p target)
            (delete-buffer target))))
      (llm-workflow-log "SUMMARY STATIC ~a failures=~d"
                        (if (zerop failures) "PASS" "FAIL") failures))))

(define-command lem-yath-test-llm-workflow-settings () ()
  (setf *llm-backend* :codex
        *llm-model* "fixture-model"
        *llm-system-message* "fixture system"
        *llm-temperature* 0.7
        *llm-max-tokens* 1234
        *llm-current-preset* "fixture-preset")
  (llm-workflow-log "SETTINGS ready"))

(define-command lem-yath-test-llm-workflow-region () ()
  (switch-to-buffer *llm-workflow-source-buffer*)
  (setf (buffer-read-only-p *llm-workflow-source-buffer*) nil)
  (buffer-mark-cancel *llm-workflow-source-buffer*)
  (erase-buffer *llm-workflow-source-buffer*)
  (insert-string (buffer-start-point *llm-workflow-source-buffer*)
                 (format nil "prefix HANDOFFREGION suffix~%"))
  (buffer-start (buffer-point *llm-workflow-source-buffer*))
  (clear-buffer-edit-history *llm-workflow-source-buffer*)
  (llm-workflow-log "REGION ready"))

(define-command lem-yath-test-llm-workflow-long () ()
  (switch-to-buffer *llm-workflow-source-buffer*)
  (setf (buffer-read-only-p *llm-workflow-source-buffer*) nil)
  (buffer-mark-cancel *llm-workflow-source-buffer*)
  (erase-buffer *llm-workflow-source-buffer*)
  (insert-string (buffer-start-point *llm-workflow-source-buffer*)
                 (make-string 14000 :initial-element #\x))
  (buffer-start (buffer-point *llm-workflow-source-buffer*))
  (clear-buffer-edit-history *llm-workflow-source-buffer*)
  (llm-workflow-log "LONG ready"))

(define-command lem-yath-test-llm-workflow-capture-setup () ()
  (switch-to-buffer *llm-workflow-source-buffer*)
  (setf *llm-backend* :lem-yath-capture-test
        *llm-current-preset* "quick-lookup"
        *llm-workflow-capture-prompt* nil
        *llm-workflow-capture-buffer* nil)
  (llm-workflow-log "CAPTURE ready"))

(define-command lem-yath-test-llm-workflow-capture-record () ()
  (let* ((buffer (current-buffer))
         (text (points-to-string (buffer-start-point buffer)
                                 (buffer-end-point buffer)))
         (path (buffer-filename buffer))
         (owner-p (eq buffer *llm-workflow-capture-buffer*))
         (heading-p (not (null (search "* Daily capture prompt :llm:" text))))
         (topic-p
           (not (null (search ":GPTEL_TOPIC: Daily capture prompt" text))))
         (preset-p
           (not (null (search ":GPTEL_PRESET: quick-lookup" text))))
         (id-line
           (find-if
            (lambda (line) (alexandria:starts-with-subseq ":ID: " line))
            (uiop:split-string text :separator '(#\Newline))))
         (id-p
           (and id-line (llm-workflow-uuid-v4-p (subseq id-line 5))))
         (response-p
           (not (null (search "CAPTURE-RESPONSE-SENTINEL" text))))
         (no-shared-p (not (search "UNEXPECTED-SHARED-CAPTURE" text)))
         (closed-p (not (search "CAPTURE-RESPONSE-SENTINEL\n\n* " text)))
         (prompt-p
           (string= *llm-workflow-capture-prompt* "Daily capture prompt"))
         (ordinary-p (not (llm-conversation-buffer-p buffer)))
         (released-p (null (llm-active-request buffer)))
         (pass
           (and owner-p
                path
                heading-p topic-p preset-p id-p response-p no-shared-p
                closed-p prompt-p ordinary-p released-p)))
    (llm-workflow-log
     "CAPTURE DETAIL owner=~a heading=~a topic=~a preset=~a id=~a response=~a no-shared=~a closed=~a prompt=~a ordinary=~a released=~a"
     owner-p heading-p topic-p preset-p id-p response-p no-shared-p closed-p
     prompt-p ordinary-p released-p)
    (when pass (save-buffer buffer))
    (llm-workflow-log "CAPTURE ~a path=~a modified=~a"
                      (if pass "PASS" "FAIL")
                      (and path (namestring path))
                      (if (buffer-modified-p buffer) "yes" "no"))
    (switch-to-buffer *llm-workflow-source-buffer*)))

(define-command lem-yath-test-llm-workflow-routing-setup () ()
  (switch-to-buffer *llm-workflow-source-buffer*)
  (setf (buffer-read-only-p *llm-workflow-source-buffer*) nil
        *llm-backend* :lem-yath-routing-test
        *llm-model* "routing-model"
        *llm-workflow-routing-dispatches* 0
        *llm-workflow-routing-prompt* nil
        *llm-workflow-routing-messages* nil)
  (buffer-mark-cancel *llm-workflow-source-buffer*)
  (erase-buffer *llm-workflow-source-buffer*)
  (insert-string (buffer-start-point *llm-workflow-source-buffer*)
                 "ROUTING-PROMPT")
  (buffer-end (buffer-point *llm-workflow-source-buffer*))
  (dolist (name (list *llm-workflow-routing-target-name*
                      *llm-workflow-routing-session-name*))
    (alexandria:when-let ((buffer (get-buffer name)))
      (when (member buffer (buffer-list) :test #'eq)
        (delete-buffer buffer))))
  (let ((target (make-buffer *llm-workflow-routing-target-name*)))
    (insert-string (buffer-start-point target) "LEFTRIGHT")
    (buffer-start (buffer-point target))
    (character-offset (buffer-point target) 4))
  (llm-workflow-log "ROUTING ready"))

(define-command lem-yath-test-llm-workflow-routing-followup () ()
  (let ((session (get-buffer *llm-workflow-routing-session-name*)))
    (unless (and session (llm-conversation-buffer-p session))
      (editor-error "Routing session is unavailable"))
    (switch-to-buffer session)
    (setf (buffer-read-only-p session) nil
          *llm-backend* :lem-yath-routing-test
          *llm-model* "routing-model")
    (buffer-mark-cancel session)
    (buffer-end (buffer-point session))
    (insert-string (buffer-point session) "ROUTING-FOLLOWUP"))
  (llm-workflow-log "ROUTING followup-ready"))

(define-command lem-yath-test-llm-workflow-routing-record () ()
  (let* ((kill (llm-workflow-killring-head))
         (target (get-buffer *llm-workflow-routing-target-name*))
         (target-text
           (and target
                (points-to-string (buffer-start-point target)
                                  (buffer-end-point target))))
         (session (get-buffer *llm-workflow-routing-session-name*))
         (session-text
           (and session
                (points-to-string (buffer-start-point session)
                                  (buffer-end-point session))))
         (hidden
           (find-if
            (lambda (buffer)
              (alexandria:starts-with-subseq
               " *lem-yath-llm-redirect-" (buffer-name buffer)))
            (buffer-list)))
         (roles
           (format nil "~{~a~^,~}"
                   (mapcar #'llm-message-role
                           *llm-workflow-routing-messages*))))
    (llm-workflow-log
     "ROUTING dispatches=~d prompt=~a roles=~a kill=~a target=~a session-mode=~a session=~a hidden=~a"
     *llm-workflow-routing-dispatches*
     *llm-workflow-routing-prompt*
     roles
     kill
     (llm-workflow-one-line target-text)
     (if (and session (llm-conversation-buffer-p session)) "yes" "no")
     (llm-workflow-one-line session-text)
     (if hidden "yes" "no"))))

(define-command lem-yath-test-llm-workflow-preview-record () ()
  (let* ((buffer (current-buffer))
         (text (points-to-string (buffer-start-point buffer)
                                 (buffer-end-point buffer)))
         (json (handler-case (yason:parse text) (error () nil)))
         (messages (and json (gethash "messages" json)))
         (message-list (llm-json-elements messages))
         (last-message (car (last message-list))))
    (llm-workflow-log
     "PREVIEW mode=~a readonly=~a dry=~a backend=~a prompt=~a dispatches=~d"
     (if (mode-active-p buffer 'lem-yath-llm-request-preview-mode) "yes" "no")
     (if (buffer-read-only-p buffer) "yes" "no")
     (if (and json (eq (gethash "dry_run" json) t)) "yes" "no")
     (or (and json (gethash "backend" json)) "none")
     (or (and (hash-table-p last-message)
              (gethash "content" last-message))
         "none")
     *llm-workflow-routing-dispatches*)
    (llm-workflow-log
     "PREVIEW secrets=~a"
     (if (or (search "Authorization" text :test #'char-equal)
             (search "api_key" text :test #'char-equal))
         "present" "absent"))))

(define-command lem-yath-test-llm-workflow-rewrite-setup () ()
  (let ((source *llm-workflow-source-buffer*))
    (dolist (state (copy-list (llm-rewrite-states source)))
      (llm-rewrite-remove-state state))
    (dolist (name (list *llm-rewrite-diff-buffer-name*))
      (alexandria:when-let ((buffer (get-buffer name)))
        (when (llm-buffer-live-p buffer)
          (delete-buffer buffer))))
    (switch-to-buffer source)
    (when (lem-vi-mode/visual:visual-p)
      (lem-vi-mode/visual:vi-visual-end source))
    (setf (buffer-read-only-p source) nil
          *llm-backend* :lem-yath-rewrite-test
          *llm-model* "rewrite-model"
          *llm-workflow-rewrite-dispatches* 0
          *llm-workflow-rewrite-prompt* nil
          *llm-workflow-rewrite-system* nil)
    (buffer-mark-cancel source)
    (erase-buffer source)
    (insert-string (buffer-start-point source) "OLD")
    (buffer-start (buffer-point source))
    (buffer-unmark source)
    (llm-workflow-log "REWRITE ready")))

(define-command lem-yath-test-llm-workflow-rewrite-record () ()
  (let* ((source *llm-workflow-source-buffer*)
         (states (llm-rewrite-states source))
         (state (first states))
         (preview (and state (llm-rewrite-state-preview-buffer state)))
         (hidden
           (find-if
            (lambda (buffer)
              (alexandria:starts-with-subseq
               " *lem-yath-llm-rewrite-" (buffer-name buffer)))
            (buffer-list))))
    (llm-workflow-log
     (concatenate
      'string
      "REWRITE source=~a pending=~d response=~a preview=~a focus=~a dispatches=~d "
      "prompt=~a system=~a forward=~a hidden=~a modified=~a")
     (llm-workflow-one-line
      (points-to-string (buffer-start-point source) (buffer-end-point source)))
     (length states)
     (llm-workflow-one-line
      (and state (llm-rewrite-state-response state)))
     (if (and (llm-buffer-live-p preview)
              (mode-active-p preview 'lem-yath-llm-rewrite-preview-mode))
         "yes" "no")
     (cond
       ((eq (current-buffer) preview) "preview")
       ((eq (current-buffer) source) "source")
       (t (buffer-name (current-buffer))))
     *llm-workflow-rewrite-dispatches*
     (llm-workflow-one-line *llm-workflow-rewrite-prompt*)
     (if (and *llm-workflow-rewrite-system*
              (search "Generate ONLY" *llm-workflow-rewrite-system*))
         "rewrite" "wrong")
     (if (llm-forward-request-buffer source) "yes" "no")
     (if hidden "yes" "no")
     (if (buffer-modified-p source) "yes" "no"))))

(define-command lem-yath-test-llm-workflow-variant-setup () ()
  (let ((buffer *llm-workflow-source-buffer*))
    (switch-to-buffer buffer)
    (setf (buffer-read-only-p buffer) nil)
    (buffer-mark-cancel buffer)
    (when (lem-vi-mode/visual:visual-p)
      (lem-vi-mode/visual:vi-visual-end buffer))
    (erase-buffer buffer)
    (unless (mode-active-p buffer 'org-mode)
      (change-buffer-mode buffer 'org-mode))
    (unless (llm-conversation-buffer-p buffer)
      (lem-yath-llm-conversation-mode t))
    (insert-string (buffer-end-point buffer) (format nil "* QUESTION~2%")
                   'lem-yath-llm-role :user)
    (insert-string (buffer-end-point buffer) "VARIANT-ONE"
                   'lem-yath-llm-role :assistant)
    (insert-string (buffer-end-point buffer) (format nil "~2%* ")
                   'lem-yath-llm-role :user)
    (buffer-start (buffer-point buffer))
    (character-offset (buffer-point buffer) 13)
    (clear-buffer-edit-history buffer)
    (setf *llm-backend* :lem-yath-variant-test
          *llm-model* "variant-model"
          *llm-system-message* "variant system"
          *llm-temperature* 0.55d0
          *llm-max-tokens* 321
          *llm-use-tools* nil
          *llm-workflow-variant-dispatches* 0
          *llm-workflow-variant-prompt* nil
          *llm-workflow-variant-messages* nil
          *llm-workflow-variant-settings* nil)
    (llm-role-refresh-static-overlays buffer)
    (llm-workflow-log "VARIANT ready")))

(define-command lem-yath-test-llm-workflow-variant-cli-setup () ()
  (call-command 'lem-yath-test-llm-workflow-variant-setup nil)
  (setf *llm-backend* :codex)
  (llm-workflow-log "VARIANT cli-ready"))

(define-command lem-yath-test-llm-workflow-variant-fail-setup () ()
  (call-command 'lem-yath-test-llm-workflow-variant-setup nil)
  (setf *llm-backend* :lem-yath-variant-fail-test)
  (llm-workflow-log "VARIANT fail-ready"))

(define-command lem-yath-test-llm-workflow-variant-record () ()
  (let ((buffer *llm-workflow-source-buffer*))
    (with-point ((response (buffer-start-point buffer)))
      (search-forward response "VARIANT-")
      (let* ((state (llm-response-current-state response))
             (history (and state (llm-response-state-history state)))
             (messages *llm-workflow-variant-messages*)
             (roles (mapcar #'llm-message-role messages))
             (contents (mapcar #'llm-message-content messages))
             (selection
               (when (buffer-mark-p buffer)
                 (multiple-value-bind (start end)
                     (let ((global-mode (current-global-mode)))
                       (values
                        (region-beginning-using-global-mode global-mode buffer)
                        (region-end-using-global-mode global-mode buffer)))
                   (points-to-string start end)))))
        (multiple-value-bind (start end) (llm-response-span-bounds response)
          (llm-workflow-log
           (concatenate
            'string
            "VARIANT response=~a history=~{~a~^,~} dispatches=~d prompt=~a "
            "roles=~{~a~^,~} contents=~{~a~^,~} settings=~{~a~^,~} "
            "active=~a visual=~a selection=~a")
           (llm-workflow-one-line (points-to-string start end))
           (mapcar #'llm-workflow-one-line history)
           *llm-workflow-variant-dispatches*
           (llm-workflow-one-line *llm-workflow-variant-prompt*)
           roles
           (mapcar #'llm-workflow-one-line contents)
           *llm-workflow-variant-settings*
           (if (llm-active-request buffer) "yes" "no")
           (if (lem-vi-mode/visual:visual-p) "yes" "no")
           (llm-workflow-one-line selection)))))))

(define-command lem-yath-test-llm-workflow-record () ()
  (let* ((preset-file (llm-preset-pathname))
         (preset-directory (uiop:pathname-directory-pathname preset-file))
         (saved (assoc "fixture-preset" (llm-read-user-presets)
                       :test #'string=))
         (kill (llm-workflow-killring-head)))
    (llm-workflow-log
     (concatenate
      'string
      "STATE current=~a backend=~a model=~a system=~a temperature=~a max=~a "
      "tools=~a saved=~a file-mode=~a dir-mode=~a kill-length=~d kill-truncated=~a")
     *llm-current-preset* *llm-backend* *llm-model* *llm-system-message*
     *llm-temperature* (or *llm-max-tokens* "none")
     (if *llm-use-tools* "yes" "no")
     (if saved "yes" "no")
     (if (uiop:file-exists-p preset-file)
         (llm-workflow-mode-bits preset-file) "none")
     (if (uiop:directory-exists-p preset-directory)
         (llm-workflow-mode-bits preset-directory) "none")
     (length kill)
     (if (and (<= (length "[Truncated by Lem") (length kill))
              (string= "[Truncated by Lem" kill
                       :end2 (length "[Truncated by Lem")))
         "yes" "no"))))

(dolist (keymap (list *global-keymap*
                      lem-vi-mode:*normal-keymap*
                      lem-vi-mode:*insert-keymap*
                      lem-vi-mode:*visual-keymap*))
  (define-key keymap "F2" 'lem-yath-test-llm-workflow-static)
  (define-key keymap "F3" 'lem-yath-test-llm-workflow-settings)
  (define-key keymap "F4" 'lem-yath-test-llm-workflow-routing-followup)
  (define-key keymap "F5" 'lem-yath-test-llm-workflow-region)
  (define-key keymap "F6" 'lem-yath-test-llm-workflow-long)
  (define-key keymap "F7" 'lem-yath-test-llm-workflow-capture-setup)
  (define-key keymap "F8" 'lem-yath-test-llm-workflow-capture-record)
  (define-key keymap "F9" 'lem-yath-test-llm-workflow-routing-setup)
  (define-key keymap "F10" 'lem-yath-test-llm-workflow-routing-record)
  (define-key keymap "F11" 'lem-yath-test-llm-workflow-preview-record)
  (define-key keymap "F12" 'lem-yath-test-llm-workflow-record)
  (define-key keymap "F1" 'lem-yath-test-llm-workflow-variant-record))

(llm-workflow-log "READY")
