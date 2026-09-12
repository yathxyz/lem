;;;; Test fixtures only. Product systems and configured managers must already exist.
;;;; No Quicklisp/ASDF loads, credentials, network transport, or runtime replacements.
(defpackage :lem-native-agent-fixture
  (:use :cl)
  (:local-nicknames (:agent :lem-agent) (:ui :lem-agent/ui)
                    (:jobs :lem-toolkit/jobs) (:proposals :lem-buffer-proposals)))
(in-package :lem-native-agent-fixture)

(defvar *root* nil)
(defvar *python* nil)
(defvar *gates* (make-hash-table :test 'equal))
(defvar *gate-lock* (bt2:make-lock :name "native fixture gates"))
(defstruct gate (lock (bt2:make-lock)) (wake (bt2:make-condition-variable)) open)

(defun field (object name) (gethash name object))
(defun json (value) (with-output-to-string (out) (yason:encode value out)))
(defun session (id)
  (or (agent:find-session ui:*default-manager* id) (error "Unknown fixture session")))
(defun snapshot (id) (agent:session-snapshot (session id)))
(defun pending (id)
  (find "pending" (field (snapshot id) "decisions")
        :key (lambda (item) (field item "status")) :test #'equal))
(defun task-message (request)
  (loop for message across (reverse (field request "messages"))
        when (equal "user" (field message "role")) return (field message "content")))
(defun call-tool (id name arguments)
  (agent:json-object "tool_calls" (vector (agent:json-object "id" id "name" name "arguments" arguments))))

(defun gate-for (id)
  (bt2:with-lock-held (*gate-lock*)
    (or (gethash id *gates*) (setf (gethash id *gates*) (make-gate)))))
(defun release-stream (id)
  (let ((gate (gate-for id)))
    (bt2:with-lock-held ((gate-lock gate))
      (setf (gate-open gate) t) (bt2:condition-broadcast (gate-wake gate))))
  t)
(defun wait-stream (context)
  (let* ((id (agent:operation-session-id context)) (gate (gate-for id)))
    (agent:register-cancellation context (lambda () (release-stream id)))
    (bt2:with-lock-held ((gate-lock gate))
      (loop until (gate-open gate)
            do (unless (bt2:condition-wait (gate-wake gate) (gate-lock gate) :timeout 90)
                 (error "Native fixture stream deadline exceeded"))))
    (agent:check-operation context)))

(defun provider (request emit context)
  (let* ((messages (field request "messages")) (last (aref messages (1- (length messages))))
         (task (task-message request)))
    (cond
      ((uiop:string-prefix-p "stream:" task)
       (funcall emit (format nil "~a stream λ" (subseq task 7)))
       (wait-stream context)
       (funcall emit " completed")
       (agent:json-object))
      ((uiop:string-prefix-p "complete:" task)
       (agent:json-object "content" (subseq task 9)))
      ((uiop:string-prefix-p "process:" task)
       (if (equal "tool" (field last "role"))
           (agent:json-object "content" "process round completed")
           (let* ((kind (subseq task 8))
                  (long (member kind '("long" "crash") :test #'equal)))
             (call-tool "process" "run_process"
                        (agent:json-object
                         "argv" (vector *python* (concatenate 'string *root* (if long "long.py" "once.py"))
                                        (concatenate 'string *root* kind))
                         "timeout_ms" 60000 "output_limit" 512)))))
      ((uiop:string-prefix-p "edit:" task)
       (cond
         ((not (equal "tool" (field last "role")))
          (call-tool "inspect" "read_file" (agent:json-object "path" "source.txt")))
         ((equal "read_file" (field last "name"))
          (let ((inspection (field last "content")))
            (call-tool "stage" "propose_edit"
                       (agent:json-object "path" "source.txt" "revision" (field inspection "revision")
                                          "original" (field inspection "content") "replacement" (subseq task 5)))))
         (t (agent:json-object "content" "edit proposal staged"))))
      (t (error "Unknown native fixture task")))))

(defun install (root python)
  (assert ui:*default-manager* () "Configured native agent manager is missing")
  (assert (jobs:job-manager-ready-p jobs:*default-manager*) () "Configured shared job manager is missing")
  ;; Inspection only: registration belongs to configured startup, not the fixture.
  (dolist (name '("list_directory" "read_file" "propose_edit" "run_process"))
    (assert (gethash name (agent::manager-tools ui:*default-manager*)) ()
            "Configured native tool is missing: ~a" name))
  (setf *root* root *python* python)
  (agent:register-provider ui:*default-manager* "native-acceptance-fake" #'provider)
  t)

(defun new-session (&optional retained-turns)
  (agent:session-id (agent:create-session ui:*default-manager* :provider "native-acceptance-fake"
                                         :model "fixture-no-network" :root *root*
                                         :limits (when retained-turns (agent:json-object "turns" retained-turns)))))

(defun session-initialized-p (id)
  ;; Nonblocking administrative receipt inspection, never awaiting on the editor.
  (let ((receipt (agent:session-ready (session id))))
    (bt2:with-lock-held ((agent::receipt-lock receipt))
      (and (agent::receipt-done receipt) (null (agent::receipt-error receipt))))))

(defun retained-reviews (id)
  (coerce (agent:list-retained-reviews (session id)) 'vector))

(defun draft (id)
  (lem-agent/drafts:find-draft ui:*default-draft-store* id))

(defun composer-draft (name)
  ;; Cached metadata only; durability is checked separately through FIND-DRAFT.
  (agent:json-copy (lem:buffer-value (lem:get-buffer name) 'ui::draft-record)))

(defun draft-retired-p (id)
  ;; Nonblocking administrative inspection of the exact draft's writer/claim.
  (let ((store ui:*default-draft-store*))
    (bt2:with-lock-held ((lem-agent/drafts::draft-store-lock store))
      (not (or (gethash id (lem-agent/drafts::draft-store-owners store))
               (gethash id (lem-agent/drafts::draft-store-retiring store))
               (gethash id (lem-agent/drafts::draft-store-pending store))
               (gethash id (lem-agent/drafts::draft-store-active store)))))))

(defun prompt-label ()
  (let ((prompt (lem-core::frame-prompt-window (lem:current-frame))))
    (if prompt
        (lem/prompt-window::prompt-buffer-prompt-string (lem:window-buffer prompt)) "")))

(defun point-at-text (buffer-name needle)
  (let* ((buffer (lem:get-buffer buffer-name)) (offset (search needle (lem:buffer-text buffer))))
    (assert offset () "Fixture view has not rendered its exact row")
    (lem:switch-to-buffer buffer)
    (lem:move-to-position (lem:current-point) (1+ offset))
    (lem:redraw-display :force t)
    t))

(defun editor-file-identities ()
  (coerce (sort (loop for buffer in (lem:buffer-list)
                     when (lem:buffer-filename buffer)
                       collect (vector (lem:buffer-name buffer) (lem:buffer-filename buffer)))
                #'string< :key (lambda (entry) (aref entry 0))) 'vector))

(defun loaded-session-ids ()
  (coerce (sort (mapcar #'agent:session-id (agent:manager-sessions ui:*default-manager*)) #'string<) 'vector))

(defun prepare-recovery-region (text)
  ;; Fresh scratch text is deliberate administrative setup, never filename lookup
  ;; or a product candidate-rebinding path. Human commands choose the exact record.
  (let ((buffer (lem:make-buffer (lem:unique-buffer-name "*Native candidate recovery source*"))))
    (lem:insert-string (lem:buffer-point buffer) text)
    (lem:clear-buffer-edit-history buffer)
    (select-recovery-region (lem:buffer-name buffer))
    (lem:buffer-name buffer)))

(defun select-recovery-region (name)
  (let ((buffer (lem:get-buffer name)))
    (lem:switch-to-buffer buffer)
    (lem:buffer-start (lem:buffer-point buffer))
    (lem:set-cursor-mark (lem:buffer-point buffer) (lem:buffer-end-point buffer))
    (lem:redraw-display :force t)
    t))

(defun edit-recovery-region-during-prompt (name)
  ;; Administrative race injection: daemon prompt ownership serializes keyboard
  ;; input from other clients. No product functions are replaced or injected.
  (let ((buffer (lem:get-buffer name)))
    (lem:insert-string (lem:buffer-end-point buffer) " HUMAN changed during prompt")
    (lem:redraw-display :force t)
    (lem:buffer-text buffer)))

(defun show (id kind)
  (let* ((session (session id))
         (buffer (ecase kind
                   (:transcript (ui:show-session session))
                   (:decisions (ui:show-decisions session))
                   (:composer (ui:show-composer session)))))
    (lem:switch-to-buffer buffer)
    (lem:redraw-display :force t)
    (lem:buffer-name buffer)))

(defun point-at-decision (buffer-name id)
  (let* ((buffer (lem:get-buffer buffer-name))
         (offset (search (format nil "Decision ~a" id) (lem:buffer-text buffer))))
    (assert offset () "The decision is not yet rendered")
    (lem:switch-to-buffer buffer)
    (lem:move-to-position (lem:current-point) (1+ offset))
    (lem:redraw-display :force t)
    t))

(defun tool-results (id name)
  (coerce (loop for turn across (field (snapshot id) "turns")
                append (loop for message across (field turn "messages")
                             when (and (equal "tool" (field message "role"))
                                       (equal name (field message "name")))
                               collect (field message "content"))) 'vector))

(defun session-jobs (id)
  (let ((prefix (format nil "agent:~a:" id)))
    (coerce (loop for job in (jobs:list-jobs)
                  when (uiop:string-prefix-p prefix (jobs:job-owner job))
                    collect (jobs:job-snapshot job)) 'vector)))

(defun journal-directories ()
  (let ((directories
          (agent:json-object "agents" (uiop:native-namestring (agent::manager-directory ui:*default-manager*))
                             "jobs" (uiop:native-namestring (jobs::manager-directory jobs:*default-manager*)))))
    (when ui:*default-draft-store*
      (setf (gethash "drafts" directories)
            (uiop:native-namestring (lem-agent/drafts::draft-store-directory ui:*default-draft-store*))))
    directories))

(defun source-buffer () (lem:get-file-buffer (concatenate 'string *root* "source.txt")))
(defun prepare-source ()
  ;; Administrative fixture setup of a private file; subsequent edits use a PTY.
  (let ((buffer (lem:find-file-buffer (concatenate 'string *root* "source.txt"))))
    (lem:clear-buffer-edit-history buffer)
    (lem:erase-buffer buffer)
    (lem:insert-string (lem:buffer-point buffer) "human unsaved original")
    (lem:buffer-name buffer)))
(defun show-source (&optional (offset 0))
  (lem:switch-to-buffer (source-buffer))
  (lem:move-to-position (lem:current-point) (1+ offset))
  (lem:redraw-display :force t)
  t)
(defun show-proposal (id)
  (proposals:show-proposal (proposals:find-proposal id))
  (lem:redraw-display :force t)
  t)
