(defpackage :lem-agent/ui
  (:use :cl :lem)
  (:local-nicknames (:agent :lem-agent) (:drafts :lem-agent/drafts))
  (:export :*default-manager* :*default-provider* :*default-model*
           :show-session :show-decisions :show-composer :show-session-list
           :submit-composer :composer-status
           :agent-new-session :agent-session-list :agent-open-session
           :agent-compose :agent-submit :agent-decisions :agent-allow :agent-deny
           :agent-answer :agent-interrupt :agent-resume :agent-close-session
           :agent-refresh :agent-close-view :agent-composer-status
           :*default-draft-store* :*require-durable-drafts* :show-draft-list :show-draft :restore-draft :checkpoint-composer
           :agent-draft-list :agent-inspect-draft :agent-restore-draft :agent-discard-draft :agent-checkpoint-draft))
(in-package :lem-agent/ui)

(defvar *default-manager* nil "Configured by the host after worker-side startup.")
(defvar *default-draft-store* nil "Opened on a startup worker after core session restoration.")
(defvar *require-durable-drafts* nil "Configured hosts refuse new composers if durable draft storage is unavailable.")
(defvar *default-provider* "openrouter")
(defvar *default-model* nil "Explicitly configured model; no implicit model selection.")
(defparameter *render-limit* 65536)
(defparameter *maximum-views* 32)
(defparameter *maximum-pending-requests* 32)
(defvar *views* (make-hash-table :test 'eq))
(defvar *pending-requests* 0)             ; editor-owned
(defvar *buffer-sequence* 0)              ; editor-owned, never identity by name
(defvar *composers* (make-hash-table :test 'eq))
(defvar *draft-views* (make-hash-table :test 'eq))

(defstruct (view (:constructor make-view (buffer session manager kind)))
  buffer session manager kind subscription
  (lock (bt2:make-lock :name "agent view"))
  (wake (bt2:make-condition-variable))
  (dirty t) queued dead worker)

(defvar *view-keymap* (make-keymap :description "Native agent view"))
(defvar *composer-keymap* (make-keymap :description "Native agent message"))
(define-major-mode agent-view-mode nil (:name "Agent" :keymap *view-keymap*))
(define-major-mode agent-composer-mode nil (:name "Agent message" :keymap *composer-keymap*))
(defvar *draft-list-keymap* (make-keymap :description "Agent draft recovery"))
(define-major-mode agent-draft-list-mode nil (:name "Agent drafts" :keymap *draft-list-keymap*))

(defun require-editor-thread ()
  (let ((editor (find-editor-thread)))
    (when (and editor (not (eq editor (bt2:current-thread))))
      (error "Agent buffer operations require the editor thread"))))

(defun field (object name &optional default)
  (if (hash-table-p object) (gethash name object default) default))

(defun new-buffer (label &key editable)
  (loop for name = (format nil "*Agent ~a ~d*" label (incf *buffer-sequence*))
        unless (get-buffer name)
          return (make-buffer name :enable-undo-p editable)))

(defun safe-error (condition)
  ;; Do not print arbitrary adapter conditions: they can carry headers or bodies.
  (format nil "Operation failed (~a). Inspect the session status; draft retained."
          (type-of condition)))

(defun set-status (buffer text)
  (setf (buffer-value buffer 'operation-status) text
        (variable-value 'modeline-format :buffer buffer)
        (list "  " 'modeline-name "  " text)))

(defun composer-status (buffer)
  (require-editor-thread)
  (let ((status (buffer-value buffer 'operation-status)))
    (if (gethash buffer *composers*)
        (format nil "~a; ~a" status (draft-checkpoint-status buffer))
        status)))

(defun request-refresh (view)
  ;; The subscriber only signals an already existing worker; no snapshot copying.
  (bt2:with-lock-held ((view-lock view))
    (unless (view-dead view)
      (setf (view-dirty view) t)
      (bt2:condition-notify (view-wake view)))))

(defun retire-view (buffer)
  (let ((view (gethash buffer *views*)))
    (when view
      (remhash buffer *views*)
      (bt2:with-lock-held ((view-lock view))
        (setf (view-dead view) t)
        (bt2:condition-notify (view-wake view)))
      (when (view-subscription view)
        (agent:unsubscribe-session (view-session view) (view-subscription view))))))

(defun buffer-killed (buffer)
  (remhash buffer *draft-views*)
  (when (gethash buffer *composers*)
    (checkpoint-composer buffer)
    (when (buffer-value buffer 'draft-store)
      (drafts:release-draft (buffer-value buffer 'draft-store)
                            (field (buffer-value buffer 'draft-record) "id")
                            (buffer-value buffer 'draft-owner)))
    (remhash buffer *composers*))
  (retire-view buffer)
  ;; Receipts still complete. Killed buffers cannot be reused by a late callback.
  (setf (buffer-value buffer 'agent-input-dead) t))

(add-hook (variable-value 'kill-buffer-hook :global t) 'buffer-killed)

(defun json-text (value)
  (with-output-to-string (out) (yason:encode value out)))

(defun format-view (view)
  "Worker-only bounded text plus exact action spans; no editor object reads."
  (let ((text (make-array 0 :element-type 'character :adjustable t :fill-pointer 0))
        (spans nil)
        (limit *render-limit*))
    (labels ((add (string &optional identity)
               (let* ((start (length text))
                      (available (max 0 (- limit start)))
                      (count (min available (length string))))
                 (loop for i below count do (vector-push-extend (char string i) text))
                 ;; A truncated operation is never actionable.
                 (when (and identity (= count (length string)))
                   (push (list start (length text) identity) spans))
                 (= count (length string))))
             (line (control &rest arguments)
               (add (apply #'format nil control arguments)))
             (decision (item session)
               (let ((block (format nil "~%Decision ~a [~a, ~a]~%Question: ~a~%Tool: ~a~%Arguments: ~a~%Choices: ~a~%"
                                    (field item "id") (field item "kind") (field item "status")
                                    (field item "question") (or (field item "tool") "none")
                                    (json-text (field item "arguments"))
                                    (json-text (field item "choices")))))
                 (add block (when (equal "pending" (field item "status"))
                              (list :decision session item))))))
      (if (eq (view-kind view) :list)
          (progn
            (line "Agent sessions — Return opens the row; g refreshes~2%")
            (loop for session in (agent:manager-sessions (view-manager view))
                  for snapshot = (agent:session-snapshot session)
                  while (< (length text) limit)
                  do (add (format nil "~a  ~a  ~a  ~a~%"
                                  (agent:session-id session) (field snapshot "status" "initializing")
                                  (field snapshot "model" "") (field snapshot "root" ""))
                          (list :session session))))
          (let* ((session (view-session view))
                 (snapshot (agent:session-snapshot session)))
            (line "Session ~a~%Status: ~a   Durability: ~a~%Provider: ~a   Model: ~a~%Root: ~a~%"
                  (agent:session-id session) (field snapshot "status" "initializing")
                  (field snapshot "durability" "ok") (field snapshot "provider" "")
                  (field snapshot "model" "") (field snapshot "root" ""))
            (line "c compose   p decisions   i interrupt   r resume   x close session   q close view~%")
            (when (member (field snapshot "status") '("interrupted" "failed") :test #'equal)
              (line "Work stopped. Unknown tool outcomes are not replayed; queued messages need deliberate resume.~%"))
            (dolist (name '("reason" "failure" "error"))
              (when (field snapshot name) (line "~a: ~a~%" name (json-text (field snapshot name)))))
            (loop for item across (field snapshot "diagnostics" #())
                  do (line "Diagnostic: ~a~%" item))
            (line "~%Queued follow-ups: ~d~%" (length (field snapshot "queue" #())))
            (loop for item across (field snapshot "queue" #())
                  for queued-text = (field item "text")
                  do (line "Queued ~a: ~a~a~%" (field item "id")
                           (subseq queued-text 0 (min 512 (length queued-text)))
                           (if (> (length queued-text) 512) " [preview truncated]" "")))
            (if (eq (view-kind view) :decisions)
                (progn
                  (line "~%On a pending decision: a allow / d deny / e edit clarification answer.~%")
                  (line "Each action applies only to the complete decision block under point.~%")
                  ;; Pending first: previous decisions cannot hide the actionable record.
                  (loop for item across (field snapshot "decisions" #())
                        when (equal "pending" (field item "status")) do (decision item session))
                  (loop for item across (field snapshot "decisions" #())
                        unless (equal "pending" (field item "status")) do (decision item session)))
                (progn
                  (line "Pending decisions: ~d (p to inspect exact tools and arguments)~%"
                        (count "pending" (field snapshot "decisions" #())
                               :key (lambda (item) (field item "status")) :test #'equal))
                  (line "Omitted earlier turns: ~d~%" (field snapshot "omitted_turns" 0))
                  (when (plusp (length (field snapshot "stream" "")))
                    (line "~%Streaming:~%~a~%" (field snapshot "stream")))
                  (line "~%Turns below are newest first; messages within each turn are chronological.~%")
                  ;; Newest turns first ensures current work stays within the display bound.
                  (loop for turn across (reverse (field snapshot "turns" #()))
                        while (< (length text) limit)
                        do (line "~%--- Turn ~a [~a] ---~%" (field turn "id") (field turn "status"))
                           (loop for message across (field turn "messages" #())
                                 while (< (length text) limit)
                                 do (line "~%~a~a:~%~a~%" (field message "role")
                                          (if (field message "name")
                                              (format nil " (~a)" (field message "name")) "")
                                          (let ((content (field message "content")))
                                            (if (stringp content) content (json-text content))))
                                    (when (field message "interrupted") (line "[Interrupted response]~%"))
                                    (loop for call across (field message "tool_calls" #())
                                          do (line "Tool call ~a: ~a ~a~%" (field call "id")
                                                   (field call "name") (json-text (field call "arguments"))))))))))
      (when (= (length text) limit)
        ;; The marker is outside the content budget; its fixed size is included in tests.
        (loop for character across (format nil "~%[Display truncated; session history remains stored.]~%")
              do (vector-push-extend character text)))
      (values (coerce text 'simple-string) (nreverse spans)))))

(defun apply-render (view text spans)
  (unwind-protect
       (let ((buffer (view-buffer view)))
         (unless (or (view-dead view) (deleted-buffer-p buffer)
                     (not (eq view (gethash buffer *views*))))
           (let ((position (position-at-point (buffer-point buffer)))
                 (old-target (text-property-at (buffer-point buffer) 'agent-target)))
             (with-buffer-read-only buffer nil
               (erase-buffer buffer)
               (insert-string (buffer-point buffer) text)
               (dolist (span spans)
                 (destructuring-bind (start end identity) span
                   (with-point ((left (buffer-start-point buffer)) (right (buffer-start-point buffer)))
                     (move-to-position left (1+ start)) (move-to-position right (1+ end))
                     (put-text-property left right 'agent-target identity))))
               (move-to-position (buffer-point buffer) (min position (1+ (length text))))
               (let ((new-target (text-property-at (buffer-point buffer) 'agent-target)))
                 ;; A new decision must not inherit point from the previous decision.
                 (when (and new-target
                            (not (and old-target
                                      (eq (second old-target) (second new-target))
                                      (equal (field (third old-target) "id")
                                             (field (third new-target) "id")))))
                   (buffer-start (buffer-point buffer))))
               (buffer-mark-saved buffer)))))
    (bt2:with-lock-held ((view-lock view))
      (setf (view-queued view) nil)
      (bt2:condition-notify (view-wake view)))))

(defun view-loop (view)
  (loop
    (bt2:with-lock-held ((view-lock view))
      (loop until (or (view-dead view) (and (view-dirty view) (not (view-queued view))))
            do (bt2:condition-wait (view-wake view) (view-lock view)))
      (when (view-dead view) (return-from view-loop))
      (setf (view-dirty view) nil (view-queued view) t))
    (multiple-value-bind (text spans)
        (handler-case (format-view view)
          (error (condition) (values (safe-error condition) nil)))
      (bt2:with-lock-held ((view-lock view))
        (when (view-dead view) (return-from view-loop)))
      (send-event (lambda () (apply-render view text spans))))))

(defun open-view (session manager kind)
  (require-editor-thread)
  (when (>= (hash-table-count *views*) *maximum-views*)
    (editor-error "Close an agent view before opening another"))
  (let* ((buffer (new-buffer (if session (subseq (agent:session-id session) 0 8) "sessions")))
         (view (make-view buffer session manager kind)))
    (setf (gethash buffer *views*) view
          (buffer-value buffer 'agent-session) session
          (buffer-read-only-p buffer) t)
    (change-buffer-mode buffer 'agent-view-mode)
    (handler-case
        (progn
          (when session
            (setf (view-subscription view)
                  (agent:subscribe-session session (lambda (event) (declare (ignore event))
                                                      (request-refresh view)))))
          (setf (view-worker view) (bt2:make-thread (lambda () (view-loop view)) :name "agent view")))
      (error (condition) (retire-view buffer) (delete-buffer buffer) (error condition)))
    buffer))

(defun show-session (session)
  "Return a new disposable transcript buffer, without selecting a window."
  (open-view session nil :transcript))
(defun show-decisions (session) (open-view session nil :decisions))
(defun show-session-list (&optional (manager *default-manager*))
  (unless manager (editor-error "No native agent manager is configured"))
  (open-view nil manager :list))

(defun show-composer (session &key decision)
  "Return an editable draft without selecting it. DECISION is a displayed clarification."
  (require-editor-thread)
  (when (and *require-durable-drafts* (not (drafts:store-open-p *default-draft-store*)))
    (editor-error "Durable agent drafts are unavailable; inspect the host recovery report before composing"))
  (when (and decision (not (equal "clarification" (field decision "kind"))))
    (editor-error "Only clarification decisions accept an editable answer"))
  (let ((buffer (new-buffer (if decision
                               (format nil "answer ~a session ~a" (field decision "id")
                                       (subseq (agent:session-id session) 0 8))
                               (format nil "message ~a" (subseq (agent:session-id session) 0 8)))
                            :editable t)))
    (setf (buffer-value buffer 'agent-session) session
          (buffer-value buffer 'agent-decision) (and decision (agent:json-copy decision)))
    (change-buffer-mode buffer 'agent-composer-mode)
    (track-composer buffer *default-draft-store* (drafts:new-record session "" 0 0) :new t)
    (set-status buffer "Draft — C-c C-c submits; C-c C-s shows receipt status")
    buffer))

(defun track-composer (buffer store record &key new)
  (setf (gethash "decision" record) (buffer-value buffer 'agent-decision))
  (handler-case
      (setf (buffer-value buffer 'draft-owner) (and store (drafts:claim-draft store record :new new)))
    (error (condition) (delete-buffer buffer) (error condition)))
  (setf (gethash buffer *composers*) t
        (buffer-value buffer 'draft-store) store
        (buffer-value buffer 'draft-record) record
        (buffer-value buffer 'draft-tick) (buffer-modified-tick buffer))
  (when store
    (setf (buffer-value buffer 'lem-daemon/recovery::recovery-exclude) t))
  (add-hook (variable-value 'after-change-functions :buffer buffer) 'composer-changed)
  (checkpoint-composer buffer)
  buffer)

(defun capture-composer (buffer)
  (when (> (1- (position-at-point (buffer-end-point buffer))) 65536)
    (error "Draft exceeds 65536 characters"))
  (let ((record (agent:json-copy (buffer-value buffer 'draft-record))))
    (unless (= (buffer-value buffer 'draft-tick) (buffer-modified-tick buffer))
      (incf (gethash "revision" record))
      (setf (buffer-value buffer 'draft-tick) (buffer-modified-tick buffer)))
    (setf (gethash "text" record) (buffer-text buffer)
          (gethash "point" record) (1- (position-at-point (buffer-point buffer)))
          (buffer-value buffer 'draft-record) record)
    record))

(defun checkpoint-composer (buffer)
  "Capture text, point and exact authority metadata; the store writes on a worker."
  (require-editor-thread)
  (when (gethash buffer *composers*)
    (handler-case
        (let* ((record (capture-composer buffer)) (store (buffer-value buffer 'draft-store))
               (saved (and store (drafts:find-draft store (field record "id")))))
          (when (and store (not (and saved (= (field saved "revision") (field record "revision"))
                                    (= (field saved "point") (field record "point")))))
            (drafts:queue-snapshot store record :owner (buffer-value buffer 'draft-owner)))
          (setf (buffer-value buffer 'draft-checkpoint-error) nil))
      (error (condition)
        (setf (buffer-value buffer 'draft-checkpoint-error)
              (format nil "Not checkpointed (~a); text remains in memory" (type-of condition)))))))

(defun composer-changed (start end old-length)
  (declare (ignore end old-length))
  (checkpoint-composer (point-buffer start)))

(defun draft-checkpoint-status (buffer)
  (let* ((store (buffer-value buffer 'draft-store))
         (record (buffer-value buffer 'draft-record))
         (saved (and store record (drafts:find-draft store (field record "id")))))
    (or (buffer-value buffer 'draft-checkpoint-error)
        (and store (drafts:store-error store))
        (when (null store) "Not checkpointed: durable draft storage unavailable; text remains in memory")
        (if (and saved (= (field saved "revision") (field record "revision"))
                 (= (field saved "point") (field record "point")))
            "Draft checkpoint durable" "Draft checkpoint queued; latest edits remain in memory"))))

(defun checkpoint-current-composer ()
  (let ((buffer (current-buffer)))
    (when (gethash buffer *composers*)
      (checkpoint-composer buffer)
      (setf (variable-value 'modeline-format :buffer buffer)
            (list "  " 'modeline-name "  " (composer-status buffer))))))
(add-hook *post-command-hook* 'checkpoint-current-composer)

(defun async-request (buffer operation thunk &key revision clear-draft immediate
                                             (slot 'pending-request))
  (require-editor-thread)
  (when (buffer-value buffer slot)
    (editor-error "This buffer already has a pending request"))
  (when (>= *pending-requests* *maximum-pending-requests*)
    (editor-error "Too many pending agent requests"))
  (let ((token (list operation)))
    (setf (buffer-value buffer slot) token)
    (incf *pending-requests*)
    (set-status buffer (format nil "~a pending; draft retained until durable acceptance" operation))
    (handler-case
        (let ((immediate-receipt (when immediate (funcall thunk))))
          (bt2:make-thread
           (lambda ()
             (let (value failure)
               (handler-case
                   (let ((receipt (or immediate-receipt (funcall thunk))))
                     (loop
                       (multiple-value-bind (result done) (agent:await-request receipt :timeout 1)
                         (when done (setf value result) (return)))))
                 (error (condition) (setf failure (safe-error condition))))
               (send-event
                (lambda ()
                  (decf *pending-requests*)
                  (unless (or (deleted-buffer-p buffer) (buffer-value buffer 'agent-input-dead)
                              (not (eq token (buffer-value buffer slot))))
                    (setf (buffer-value buffer slot) nil)
                    (let ((unchanged (and clear-draft (= revision (buffer-modified-tick buffer)))))
                      (when (and value (not failure) unchanged)
                        (erase-buffer buffer) (buffer-mark-saved buffer))
                      (set-status buffer
                                  (or failure
                                      (if value
                                          (format nil "~a accepted~a" operation
                                                  (if (and clear-draft (not unchanged))
                                                      "; newer draft preserved" ""))
                                          (format nil "~a not accepted; decision is stale or already resolved; draft retained"
                                                  operation))))))))))
           :name "agent receipt"))
      (error (condition)
        (decf *pending-requests*)
        (setf (buffer-value buffer slot) nil)
        (set-status buffer (safe-error condition))
        (error condition)))
    token))

(defun session-for-buffer (&optional (buffer (current-buffer)))
  (or (buffer-value buffer 'agent-session)
      (editor-error "This buffer has no native agent session")))

(defun submit-composer (buffer)
  (require-editor-thread)
  (unless (eq (buffer-major-mode buffer) 'agent-composer-mode)
    (editor-error "Submit from an agent message or answer buffer"))
  (let* ((session (session-for-buffer buffer))
         (decision (buffer-value buffer 'agent-decision))
         (text (buffer-text buffer))
         (revision (buffer-modified-tick buffer)))
    (when (> (length text) 65536) (editor-error "Agent input exceeds 65536 characters"))
    (when (and (null decision) (zerop (length text))) (editor-error "Enter a message before submitting"))
    (when (buffer-value buffer 'draft-submit-disabled)
      (editor-error "~a" (buffer-value buffer 'draft-submit-disabled)))
    (let ((store (buffer-value buffer 'draft-store)))
      (when store
        (let ((record (capture-composer buffer)) (owner (buffer-value buffer 'draft-owner)))
          (return-from submit-composer
            (async-request buffer (if decision "Answer" "Message")
                           (lambda () (drafts:submit-draft store record session :owner owner))
                           :revision revision :clear-draft t :immediate t)))))
    (async-request buffer (if decision "Answer" "Message")
                   (if decision
                       (let ((id (field decision "id")))
                         (lambda () (agent:resolve-decision session id text)))
                       (lambda () (agent:submit-message session text)))
                   :revision revision :clear-draft t)))

(defun draft-availability (record manager)
  (let* ((session (and manager (agent:find-session manager (field record "session_id"))))
         (snapshot (and session (agent:session-snapshot session)))
         (decision (field record "decision")) (attempt (field record "attempt")))
    (values session
            (cond
              ((null session) "Original session unavailable; inspect or copy this text into a new deliberate draft")
              ((equal "closed" (field snapshot "status")) "Original session is closed; this draft is inspection only")
              ((and attempt (member (field attempt "status") '("prepared" "unknown") :test #'equal))
               "Submission acceptance is unknown; recover the host before submitting")
              ((and attempt (equal "accepted" (field attempt "status"))
                    (= (field attempt "revision") (field record "revision")))
               "This draft revision was already accepted; inspect or copy deliberately")
              ((and decision
                    (not (equalp decision (find (field decision "id") (field snapshot "decisions")
                                               :key (lambda (item) (field item "id")) :test #'equal))))
               "Original clarification is cancelled, resolved, or changed; this answer cannot be submitted")))))

(defun restore-draft (id &optional (store *default-draft-store*) (manager *default-manager*))
  "Return an unnamed draft buffer, without files, mode hooks, selection or submission."
  (require-editor-thread)
  (unless store (editor-error "No durable draft store is configured"))
  (loop for buffer being the hash-keys of *composers*
        when (and (eq store (buffer-value buffer 'draft-store))
                  (equal id (field (buffer-value buffer 'draft-record) "id")))
          do (return-from restore-draft buffer))
  (let ((record (or (drafts:find-draft store id) (editor-error "Draft no longer exists; refresh the list"))))
    (multiple-value-bind (session disabled) (draft-availability record manager)
      (let ((buffer (new-buffer (format nil "recovered ~a session ~a" id (field record "session_id")) :editable t)))
        (setf (buffer-value buffer 'agent-session) session
              (buffer-value buffer 'agent-decision) (field record "decision")
              (buffer-value buffer 'draft-submit-disabled) disabled
              (buffer-major-mode buffer) 'agent-composer-mode
              (buffer-syntax-table buffer) (mode-syntax-table 'agent-composer-mode))
        (insert-string (buffer-point buffer) (field record "text"))
        (move-to-position (buffer-point buffer) (1+ (field record "point")))
        (track-composer buffer store record)
        (set-status buffer (or disabled "Recovered draft; C-c C-c submits only by deliberate action"))
        buffer))))

(defun new-draft-view (label)
  (when (>= (hash-table-count *draft-views*) 8)
    (editor-error "Close a draft inspection view before opening another"))
  (let ((buffer (new-buffer label)))
    (setf (gethash buffer *draft-views*) t)
    buffer))

(defun render-draft-list (buffer store)
  (require-editor-thread)
  (unless store (editor-error "No durable draft store is configured"))
  (with-buffer-read-only buffer nil
    (erase-buffer buffer)
    (change-buffer-mode buffer 'agent-draft-list-mode)
    (setf (buffer-value buffer 'draft-inspected) nil)
    (insert-string (buffer-point buffer) (format nil "Durable agent drafts — i inspect, Return restore, d discard, g refresh, q close view~2%"))
    (dolist (record (drafts:list-drafts store))
      (with-point ((start (buffer-point buffer)))
        (insert-string (buffer-point buffer)
                       (format nil "~a  session ~a  ~a  ~a  revision ~d  ~d characters~%"
                               (field record "id") (field record "session_id")
                               (if (field record "decision") "clarification" "message")
                               (or (field (field record "attempt") "status") "unsent")
                               (field record "revision") (length (field record "text"))))
        (put-text-property start (buffer-point buffer) 'agent-draft-target
                           (list store (field record "id") (field record "revision")))))
    (buffer-start (buffer-point buffer)) (buffer-mark-saved buffer)
    (setf (buffer-value buffer 'draft-list-store) store))
  (setf (buffer-read-only-p buffer) t)
  buffer)

(defun show-draft-list (&optional (store *default-draft-store*))
  (require-editor-thread)
  (unless store (editor-error "No durable draft store is configured"))
  (render-draft-list (new-draft-view "drafts") store))

(defun show-draft (id &optional (store *default-draft-store*))
  "Read-only bounded text and exact session/decision/submission metadata."
  (require-editor-thread)
  (let* ((record (or (and store (drafts:find-draft store id)) (editor-error "Draft no longer exists")))
         (buffer (new-draft-view "draft inspection"))
         (attempt (agent:json-copy (field record "attempt")))
         (submitted (field attempt "text")))
    (when attempt (remhash "text" attempt))
    (change-buffer-mode buffer 'agent-draft-list-mode)
    (insert-string (buffer-point buffer)
                   (format nil "Draft ~a — Return restore, d discard, q close view~%Session: ~a~%Root: ~a~%Provider: ~a   Model: ~a~%Revision: ~d   Point: ~d~%Original decision: ~a~%Submission attempt: ~a~2%Complete draft text:~%~a"
                           id (field record "session_id") (field record "root") (field record "provider")
                           (field record "model") (field record "revision") (field record "point")
                           (json-text (field record "decision")) (json-text attempt)
                           (field record "text")))
    (when (and submitted (not (equal submitted (field record "text"))))
      (insert-string (buffer-point buffer) (format nil "~2%Exact submitted text (earlier revision):~%~a" submitted)))
    (put-text-property (buffer-start-point buffer) (buffer-end-point buffer) 'agent-draft-target
                       (list store id (field record "revision")))
    (buffer-start (buffer-point buffer)) (buffer-mark-saved buffer)
    (setf (buffer-read-only-p buffer) t
          (buffer-value buffer 'draft-inspected) (list id (field record "revision") (json-text (field record "attempt")))
          (buffer-value buffer 'draft-list-store) store)
    buffer))

(defun draft-target ()
  (or (text-property-at (current-point) 'agent-draft-target)
      (editor-error "Place point on a complete draft row")))

(define-command agent-draft-list () () (select-agent-buffer (show-draft-list)))
(define-command agent-inspect-draft () ()
  (destructuring-bind (store id revision) (draft-target)
    (declare (ignore revision)) (select-agent-buffer (show-draft id store))))
(define-command agent-restore-draft () ()
  (destructuring-bind (store id revision) (draft-target)
    (declare (ignore revision)) (select-agent-buffer (restore-draft id store))))
(define-command agent-discard-draft () ()
  (destructuring-bind (store id revision) (draft-target)
    (when (loop for buffer being the hash-keys of *composers*
                thereis (and (eq store (buffer-value buffer 'draft-store))
                             (equal id (field (buffer-value buffer 'draft-record) "id"))))
      (editor-error "Close the draft composer before discarding its checkpoint"))
    (let* ((record (or (drafts:find-draft store id) (editor-error "Draft no longer exists")))
           (attempt (field record "attempt"))
           (uncertain (and attempt (member (field attempt "status") '("prepared" "unknown") :test #'equal))))
      (when (and uncertain (not (equal (buffer-value (current-buffer) 'draft-inspected)
                                       (list id revision (json-text attempt)))))
        (editor-error "Inspect this exact draft with i before discarding uncertain submission evidence"))
      (when (prompt-for-y-or-n-p
             (format nil "Discard ~d characters from draft ~a, session ~a~a? "
                     (length (field record "text")) id (field record "session_id")
                     (if uncertain (format nil "; acceptance of attempt ~a remains unknown; delete its evidence" (field attempt "id")) "")))
        (async-request (current-buffer) "Draft discard"
                       (lambda () (drafts:discard-draft store id :expected-revision revision
                                                        :acknowledge-uncertainty (and uncertain t))))))))
(define-command agent-checkpoint-draft () ()
  (unless (gethash (current-buffer) *composers*) (editor-error "Checkpoint an agent composer"))
  (checkpoint-current-composer) (message "~a" (composer-status (current-buffer))))
(define-command agent-refresh-drafts () ()
  (render-draft-list (current-buffer) (buffer-value (current-buffer) 'draft-list-store)))

(defun decision-at-point ()
  (let ((target (text-property-at (current-point) 'agent-target)))
    (unless (and (eq (first target) :decision)
                 (eq (second target) (session-for-buffer))
                 (equal "pending" (field (third target) "status")))
      (editor-error "Place point inside a completely displayed pending decision"))
    target))

(defun answer-permission (answer)
  (destructuring-bind (kind session decision) (decision-at-point)
    (declare (ignore kind))
    (unless (equal "permission" (field decision "kind"))
      (editor-error "Use e to compose a clarification answer"))
    (let ((id (field decision "id")))
      (async-request (current-buffer) (if (equal answer "allow") "Approval" "Denial")
                     (lambda () (agent:resolve-decision session id answer))))))

(defun select-agent-buffer (buffer) (setf (current-window) (pop-to-buffer buffer)))

(define-command agent-new-session (root model)
    ((prompt-for-string "Agent project root (absolute): "
                        :initial-value (uiop:native-namestring (buffer-directory)))
     (prompt-for-string "Agent model: " :initial-value (or *default-model* "")))
  (unless *default-manager* (editor-error "No native agent manager is configured"))
  (let* ((session (agent:create-session *default-manager* :provider *default-provider*
                                      :model model :root root))
         (buffer (show-session session)))
    (async-request buffer "Session initialization" (lambda () (agent:session-ready session)))
    (select-agent-buffer buffer)))
(define-command agent-session-list () () (select-agent-buffer (show-session-list)))
(define-command agent-open-session () ()
  (let ((target (text-property-at (current-point) 'agent-target)))
    (unless (eq (first target) :session) (editor-error "Place point on a session row"))
    (select-agent-buffer (show-session (second target)))))
(define-command agent-compose () () (select-agent-buffer (show-composer (session-for-buffer))))
(define-command agent-submit () () (submit-composer (current-buffer)))
(define-command agent-decisions () () (select-agent-buffer (show-decisions (session-for-buffer))))
(define-command agent-allow () () (answer-permission "allow"))
(define-command agent-deny () () (answer-permission "deny"))
(define-command agent-answer () ()
  (destructuring-bind (kind session decision) (decision-at-point)
    (declare (ignore kind))
    (select-agent-buffer (show-composer session :decision decision))))
(define-command agent-interrupt () ()
  (let ((session (session-for-buffer)))
    (async-request (current-buffer) "Interrupt" (lambda () (agent:interrupt-session session))
                   :immediate t :slot 'lifecycle-request)))
(define-command agent-resume () ()
  (let ((session (session-for-buffer)))
    (async-request (current-buffer) "Resume" (lambda () (agent:resume-session session)))))
(define-command agent-close-session () ()
  (let ((session (session-for-buffer)))
    (async-request (current-buffer) "Close session" (lambda () (agent:close-session session))
                   :immediate t :slot 'lifecycle-request)))
(define-command agent-refresh () ()
  (let ((view (gethash (current-buffer) *views*))) (when view (request-refresh view))))
(define-command agent-close-view () () (delete-buffer (current-buffer)))
(define-command agent-composer-status () () (message "~a" (composer-status (current-buffer))))

(loop for (key command) on '("c" agent-compose "p" agent-decisions "a" agent-allow
                            "d" agent-deny "e" agent-answer "i" agent-interrupt
                            "r" agent-resume "x" agent-close-session "g" agent-refresh
                            "q" agent-close-view "Return" agent-open-session)
      by #'cddr do (define-key *view-keymap* key command))
(define-key *composer-keymap* "C-c C-c" 'agent-submit)
(define-key *composer-keymap* "C-c C-s" 'agent-composer-status)
(define-key *composer-keymap* "C-c C-w" 'agent-checkpoint-draft)
(loop for (key command) on '("Return" agent-restore-draft "i" agent-inspect-draft "d" agent-discard-draft
                            "g" agent-refresh-drafts "q" agent-close-view)
      by #'cddr do (define-key *draft-list-keymap* key command))
