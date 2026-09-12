(in-package :lem-agent/editor-tools)

(defstruct inspection token session root path image buffer tick start end original sequence)
(defstruct (editor-tools (:constructor make-editor-tools (dispatch)))
  dispatch (lock (bt2:make-lock :name "agent file tools")) (pending 0) (sequence 0)
  (inspections (make-hash-table :test #'equal)))
(defstruct editor-receipt (lock (bt2:make-lock :name "agent editor operation"))
  (ready (bt2:make-condition-variable)) done cancelled value error)

(defun finish-editor-receipt (receipt &key value error cancelled)
  (bt2:with-lock-held ((editor-receipt-lock receipt))
    (unless (editor-receipt-done receipt)
      (setf (editor-receipt-done receipt) t (editor-receipt-value receipt) value
            (editor-receipt-error receipt) error (editor-receipt-cancelled receipt) cancelled)
      (bt2:condition-broadcast (editor-receipt-ready receipt)))))

(defun call-on-editor (tools context function &key (timeout 10))
  "Worker-only bounded dispatch. Expired/cancelled queued callbacks are inert."
  (when (eq (lem:find-editor-thread) (bt2:current-thread))
    (error "Agent file tools must not wait on the editor thread"))
  (agent:check-operation context)
  (let ((receipt (make-editor-receipt))
        (released nil)
        (deadline (+ (get-internal-real-time) (* timeout internal-time-units-per-second))))
    (bt2:with-lock-held ((editor-tools-lock tools))
      (when (>= (editor-tools-pending tools) 64) (error "Agent editor queue is full"))
      (incf (editor-tools-pending tools)))
    (flet ((release-slot ()
             (bt2:with-lock-held ((editor-tools-lock tools))
               (unless released
                 (setf released t)
                 (decf (editor-tools-pending tools))))))
      (handler-case
          (progn
            (agent:register-cancellation
             context (lambda () (finish-editor-receipt receipt :cancelled t)))
            (funcall
             (editor-tools-dispatch tools)
             (lambda ()
               (unwind-protect
                    (handler-case
                        (unless (bt2:with-lock-held ((editor-receipt-lock receipt))
                                  (editor-receipt-done receipt))
                          (agent:check-operation context)
                          (finish-editor-receipt receipt :value (funcall function)))
                      (error (condition) (finish-editor-receipt receipt :error condition)))
                 (release-slot)))))
        (error (condition)
          (finish-editor-receipt receipt :error condition)
          (release-slot)
          (error condition))))
    (bt2:with-lock-held ((editor-receipt-lock receipt))
      (loop until (editor-receipt-done receipt)
            for remaining = (/ (- deadline (get-internal-real-time)) internal-time-units-per-second)
            do (unless (plusp remaining)
                 (setf (editor-receipt-done receipt) t (editor-receipt-cancelled receipt) t)
                 (error "Editor operation timed out before completion"))
               (bt2:condition-wait (editor-receipt-ready receipt) (editor-receipt-lock receipt)
                                   :timeout remaining))
      (when (editor-receipt-cancelled receipt) (error 'agent:operation-cancelled))
      (when (editor-receipt-error receipt) (error (editor-receipt-error receipt)))
      (agent:check-operation context)
      (editor-receipt-value receipt))))

(defun lookup-live-file-buffer (name)
  ;; Lem stores Lisp namestrings (escaping literal wildcard characters). Convert
  ;; them back to native names without TRUENAME/PROBE-FILE or glob expansion.
  (find name (lem:buffer-list) :test #'equal
        :key (lambda (buffer)
               (when (lem:buffer-filename buffer)
                 (uiop:native-namestring (lem:buffer-filename buffer))))))

(defun buffer-fragment (buffer start limit)
  (let ((size (1- (lem:position-at-point (lem:buffer-end-point buffer)))))
    (unless (<= 0 start size +maximum-file-bytes+) (error "Buffer is too large or offset is past its end"))
    (lem:with-point ((begin (lem:buffer-start-point buffer)) (end (lem:buffer-start-point buffer)))
      (lem:move-to-position begin (1+ start))
      (lem:move-to-position end (1+ (min size (+ start limit))))
      (values (lem:points-to-string begin end) (1- (lem:position-at-point end)) size))))

(defun inspection-size (inspection)
  (+ (length (inspection-original inspection))
     (if (inspection-image inspection) (length (file-image-content (inspection-image inspection))) 0)))

(defun retain-inspection (tools inspection)
  (bt2:with-lock-held ((editor-tools-lock tools))
    (let ((table (editor-tools-inspections tools)))
      (setf (inspection-sequence inspection) (incf (editor-tools-sequence tools)))
      (setf (gethash (inspection-token inspection) table) inspection)
      (loop while (or (> (hash-table-count table) 128)
                      (> (loop for value being the hash-values of table sum (inspection-size value))
                         (* 8 1024 1024)))
            for oldest = (loop for value being the hash-values of table
                               minimize (inspection-sequence value) into minimum
                               finally (return minimum))
            do (maphash (lambda (key value)
                          (when (= oldest (inspection-sequence value)) (remhash key table))) table))))
  inspection)

(defun find-inspection (tools context path token)
  (bt2:with-lock-held ((editor-tools-lock tools))
    (let ((inspection (gethash token (editor-tools-inspections tools))))
      (unless (and inspection (equal path (inspection-path inspection))
                   (equal (agent:operation-session-id context) (inspection-session inspection))
                   (equal (agent:operation-root context) (inspection-root inspection)))
        (error "Inspection revision is expired or belongs to another session/path"))
      inspection)))

(defun publish-inspection (tools context arguments image token &key live-only)
  (let* ((path (gethash "path" arguments))
         (start (gethash "offset" arguments 0))
         (limit (gethash "limit" arguments +maximum-fragment-characters+)))
    (call-on-editor
     tools context
     (lambda ()
       (block publish-inspection-callback
       (let* ((buffer (lookup-live-file-buffer (file-image-name image)))
              (content (file-image-content image))
              (size (length content)) (end nil) (fragment nil))
         (when (and live-only (null buffer)) (return-from publish-inspection-callback nil))
         (if buffer
             (multiple-value-setq (fragment end size) (buffer-fragment buffer start limit))
             (progn
               (unless (<= start size) (error "Offset is past the end of the file"))
               (setf end (min size (+ start limit)) fragment (subseq content start end))))
         (let* ((inspection
                  (make-inspection :token token
                                   :session (copy-seq (agent:operation-session-id context))
                                   :root (copy-seq (agent:operation-root context)) :path (copy-seq path)
                                   :image (unless buffer image)
                                   :buffer (when buffer (sb-ext:make-weak-pointer buffer))
                                   :tick (when buffer (lem:buffer-modified-tick buffer))
                                   :start start :end end :original fragment))
                (result (agent:json-object
                         "path" path "revision" (inspection-token inspection)
                         "source" (if buffer "buffer" (if (file-image-exists image) "disk" "new-file"))
                         "content" fragment "offset" start "end" end "length" size
                         "modified" (if (and buffer (lem:buffer-modified-p buffer)) yason:true yason:false)
                         "truncated" (if (< end size) yason:true yason:false))))
           ;; Budget before creating a token; control characters can expand JSON.
           (when (> (agent::encoded-size result) 32768) (error "Inspection text exceeds the result budget"))
           (agent:check-operation context)
           (retain-inspection tools inspection)
           (agent:json-copy result))))))))

(defun read-file-tool (tools context arguments)
  (let* ((path (gethash "path" arguments))
         ;; Path validation requires only O_PATH/fstat. An already open buffer
         ;; takes precedence without reading stale, huge or differently encoded
         ;; disk text behind the human's live document.
         (image (read-project-file context path :content-p nil))
         (token (lem-daemon/recovery-store:new-id)))
    (or (publish-inspection tools context arguments image token :live-only t)
        (publish-inspection tools context arguments (read-project-file context path) token))))

(defvar *activation-key* 'agent-file-needs-activation)

(defun prepare-file-buffer (context image)
  "Prepare private worker text without filesystem queries or file hooks."
  (agent:check-operation context)
  (let* ((name (file-image-name image))
         (basename (car (last (path-components (file-image-path image)))))
         (buffer (lem:make-buffer (if (lem:get-buffer basename) (lem:unique-buffer-name basename) basename)
                                  :enable-undo-p nil :temporary t))
         (prepared nil))
    (unwind-protect
         (progn
           ;; Both public filename/directory setters probe the filesystem. These
           ;; names were already verified using the worker's root capability.
           (setf (lem/buffer/internal::buffer-%filename buffer)
                 (namestring (sb-ext:parse-native-namestring name))
                 (lem/buffer/internal::buffer-%directory buffer)
                 (namestring (sb-ext:parse-native-namestring
                              (subseq name 0 (1+ (position #\/ name :from-end t)))))
                 (lem:buffer-last-write-date buffer) (file-image-write-date image)
                 (lem:buffer-encoding buffer)
                 (lem/buffer/encodings:encoding :utf-8 (or (file-image-end-of-line image) :lf))
                 (lem:buffer-value buffer *activation-key*) t)
           (let ((lem:*inhibit-modification-hooks* t))
             (lem:insert-string (lem:buffer-point buffer) (file-image-content image)))
           (if (file-image-exists image)
               (lem:buffer-mark-saved buffer)
               (lem/buffer/internal::buffer-modify buffer))
           (lem:buffer-enable-undo buffer)
           (lem:buffer-start (lem:buffer-point buffer))
           (setf prepared t)
           buffer)
      (unless prepared (lem/buffer/internal::buffer-free buffer)))))

(lem:define-command agent-activate-file-buffer () ()
  "Run normal file mode/setup for a buffer prepared by an agent file tool."
  (let ((buffer (lem:current-buffer)))
    (unless (lem:buffer-value buffer *activation-key*)
      (lem:editor-error "This buffer already has its normal file setup"))
    ;; This command is a deliberate human action; ordinary file hooks may query
    ;; the filesystem, start language services, or ask the user questions.
    (lem:run-hooks lem:*before-find-file-hook* (lem:buffer-filename buffer) nil)
    (lem:run-hooks lem:*find-file-hook* buffer)
    (setf (lem:buffer-value buffer *activation-key*) nil)))

(defun proposal-result (proposal path buffer)
  (let ((location (proposals:proposal-source-location proposal)))
    (agent:json-copy
     (agent:json-object "path" path "proposal_id" (proposals:proposal-id proposal)
                       "state" (string-downcase (proposals:proposal-state proposal))
                       "revision" (proposals:proposal-revision proposal)
                       "generation" (proposals:proposal-generation proposal)
                       "buffer" (lem:buffer-name buffer)
                       "line" (getf location :line) "column" (getf location :column)
                       "needs_activation" (if (lem:buffer-value buffer *activation-key*) yason:true yason:false)
                       "activation_command" "agent-activate-file-buffer"))))

(defun propose-edit-tool (tools context arguments)
  (let* ((path (gethash "path" arguments))
         (inspection (find-inspection tools context path (gethash "revision" arguments)))
         (original (gethash "original" arguments)) (replacement (gethash "replacement" arguments))
         (image (read-project-file context path :content-p (not (null (inspection-image inspection))))))
    (unless (equal original (inspection-original inspection))
      (error "Proposal original text does not match the inspected revision"))
    (when (and (inspection-image inspection)
               (not (same-file-image-p image (inspection-image inspection))))
      (error "File changed since inspection; inspect it again before proposing an edit"))
    (call-on-editor
     tools context
     (lambda ()
       ;; A token is consumed once. Two workers cannot stage from the same stale
       ;; token even if both passed the worker-side lookup before queuing.
       (unless (eq inspection (find-inspection tools context path (inspection-token inspection)))
         (error "Inspection revision was replaced"))
       (let ((buffer (lookup-live-file-buffer (file-image-name image))))
         (if (inspection-buffer inspection)
             (unless (and buffer (eq buffer (sb-ext:weak-pointer-value (inspection-buffer inspection)))
                          (not (lem:deleted-buffer-p buffer))
                          (= (inspection-tick inspection) (lem:buffer-modified-tick buffer)))
               (error "Live buffer changed or was replaced since inspection"))
             (when buffer (error "A live buffer appeared since disk inspection; inspect it again")))
         (when buffer
           (unless (equal original (buffer-fragment buffer (inspection-start inspection)
                                                   (- (inspection-end inspection) (inspection-start inspection))))
             (error "Live buffer no longer matches the inspected text")))
         (agent:check-operation context)
         (let ((proposal nil) (created nil))
           (handler-case
               (progn
                 (unless buffer
                   (setf buffer (prepare-file-buffer context image) created t))
                 (lem:with-point ((start (lem:buffer-start-point buffer)) (end (lem:buffer-start-point buffer)))
                   (lem:move-to-position start (1+ (inspection-start inspection)))
                   (lem:move-to-position end (1+ (inspection-end inspection)))
                   (unless (equal original (lem:points-to-string start end))
                     (error "Prepared buffer region does not match the inspected original"))
                   (agent:check-operation context)
                   (setf proposal (proposals:capture-region start end))
                   (proposals:stage-replacement proposal replacement)
                   (let ((result (proposal-result proposal path buffer)))
                     (agent:check-operation context)
                     (when created
                       (setf (slot-value buffer 'lem/buffer/internal::temporary) nil)
                       (lem/buffer/internal::add-buffer buffer)
                       (setf created nil))
                     (bt2:with-lock-held ((editor-tools-lock tools))
                       (remhash (inspection-token inspection) (editor-tools-inspections tools)))
                     result)))
             (error (condition)
               (when proposal
                 (ignore-errors (proposals:reject-proposal proposal) (proposals:forget-proposal proposal)))
               ;; This private buffer has never been displayed or run hooks.
               ;; Free it directly; generic deletion would invoke user hooks.
               (when created (lem/buffer/internal::buffer-free buffer))
               (error condition)))))))))

(defun validate-fields (arguments required optional)
  (unless (and (hash-table-p arguments)
               (loop for key being the hash-keys of arguments
                     always (member key (append required optional) :test #'equal))
               (every (lambda (key) (nth-value 1 (gethash key arguments))) required))
    (error "Invalid file tool argument fields"))
  (path-components (gethash "path" arguments))
  t)

(defun string-schema (&optional (maximum 4096))
  (agent:json-object "type" "string" "maxLength" maximum))
(defun object-schema (properties required description)
  (agent:json-object "type" "object" "properties" properties
                     "required" (coerce required 'vector) "additionalProperties" yason:false
                     "description" description))

(defun install-editor-tools (manager &key (dispatch #'lem:send-event))
  "Register bounded native file tools. DISPATCH enqueues editor callbacks."
  (let ((tools (make-editor-tools dispatch)))
    (agent:register-tool
     manager "list_directory"
     :schema (object-schema (agent:json-object "path" (string-schema)) '("path")
                            "List up to 128 entries under the session root. Path is literal and relative; empty means root. No symlink traversal.")
     :validate (lambda (arguments) (validate-fields arguments '("path") nil))
     :execute (lambda (arguments context) (list-project-directory context (gethash "path" arguments))))
    (agent:register-tool
     manager "read_file"
     :schema (object-schema (agent:json-object
                             "path" (string-schema)
                             "offset" (agent:json-object "type" "integer" "minimum" 0 "maximum" +maximum-file-bytes+)
                             "limit" (agent:json-object "type" "integer" "minimum" 1 "maximum" +maximum-fragment-characters+))
                            '("path")
                            "Inspect current unsaved buffer text when open, otherwise bounded UTF-8 file text. Path is root-relative. Offset and limit count characters from zero. Keep the returned revision and exact content for propose_edit.")
     :validate (lambda (arguments)
                 (validate-fields arguments '("path") '("offset" "limit"))
                 (unless (and (plusp (length (gethash "path" arguments)))
                              (typep (gethash "offset" arguments 0) `(integer 0 ,+maximum-file-bytes+))
                              (typep (gethash "limit" arguments +maximum-fragment-characters+)
                                     `(integer 1 ,+maximum-fragment-characters+)))
                   (error "Invalid file inspection range")) t)
     :execute (lambda (arguments context) (read-file-tool tools context arguments)))
    (agent:register-tool
     manager "propose_edit"
     :schema (object-schema (agent:json-object "path" (string-schema) "revision" (string-schema 128)
                                               "original" (string-schema +maximum-fragment-characters+)
                                               "replacement" (string-schema +maximum-fragment-characters+))
                            '("path" "revision" "original" "replacement")
                            "Stage a human-reviewed replacement of exactly the fragment returned by read_file. Supply its one-use revision and unchanged original content. Does not apply or save. Conflicts require a fresh read.")
     :validate (lambda (arguments)
                 (validate-fields arguments '("path" "revision" "original" "replacement") nil)
                 (unless (and (plusp (length (gethash "path" arguments)))
                              (text-p (gethash "revision" arguments) 128 1)
                              (text-p (gethash "original" arguments) +maximum-fragment-characters+)
                              (text-p (gethash "replacement" arguments) +maximum-fragment-characters+))
                   (error "Invalid bounded edit proposal")) t)
     :execute (lambda (arguments context) (propose-edit-tool tools context arguments)))
    tools))
