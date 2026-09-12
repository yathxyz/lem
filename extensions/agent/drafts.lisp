(defpackage :lem-agent/drafts
  (:use :cl)
  (:local-nicknames (:agent :lem-agent) (:disk :lem-daemon/recovery-store))
  (:export :open-store :close-store :store-open-p :store-error
           :claim-draft :release-draft
           :new-record :queue-snapshot :find-draft :list-drafts
           :submit-draft :discard-draft))
(in-package :lem-agent/drafts)

(defconstant +maximum-drafts+ 32)
(defconstant +maximum-record-bytes+ (* 1024 1024))
(defconstant +maximum-total-bytes+ (* 16 1024 1024))
(defstruct (draft-store (:constructor %make-store))
  directory manager lease worker closing closed failure
  (lock (bt2:make-lock :name "agent drafts")) (wake (bt2:make-condition-variable))
  (records (make-hash-table :test 'equal))
  (reservations (make-hash-table :test 'equal))
  (owners (make-hash-table :test 'equal)) (retiring (make-hash-table :test 'equal))
  (pending (make-hash-table :test 'equal))
  (active (make-hash-table :test 'equal))
  (recovered-unknown (make-hash-table :test 'equal)) queue tail (queued 0))

(defun field (record name) (gethash name record))
(defun (setf field) (value record name) (setf (gethash name record) value))
(defun id-p (id) (agent::valid-id-p id))
(defun text-p (text maximum &optional (minimum 0)) (agent::text-p text maximum minimum))
(defun size (record) (agent::encoded-size record))
(defun reserved-size (record)
  (+ (size record)
     (let ((attempt (field record "attempt")))
       (if (and attempt (member (field attempt "status") '("prepared" "unknown") :test #'equal)) 128 0))))
(defun valid-digest-p (digest)
  (and (text-p digest 64 64) (every (lambda (c) (find c "0123456789abcdef")) digest)))

(defun validate-record (record)
  (unless (and (hash-table-p record) (= 11 (hash-table-count record))
               (eql 1 (field record "version")) (id-p (field record "id"))
               (id-p (field record "session_id"))
               (text-p (field record "root") 8192 1) (uiop:absolute-pathname-p (field record "root"))
               (text-p (field record "provider") 128 1) (text-p (field record "model") 256 1)
               (text-p (field record "text") 65536)
               (typep (field record "revision") '(integer 0 1152921504606846975))
               (typep (field record "point") '(integer 0))
               (<= (field record "point") (length (field record "text"))))
    (error "Invalid agent draft schema"))
  (let ((decision (field record "decision")) (attempt (field record "attempt")))
    (when decision
      (unless (and (hash-table-p decision) (id-p (field decision "id"))
                   (id-p (field decision "turn_id"))
                   (typep (field decision "generation") '(integer 0))
                   (equal "clarification" (field decision "kind"))
                   (equal "pending" (field decision "status"))
                   (text-p (field decision "question") 8192 1)
                   (vectorp (field decision "choices")) (not (stringp (field decision "choices")))
                   (<= (length (field decision "choices")) 32)
                   (every (lambda (choice) (text-p choice 4096 1)) (field decision "choices"))
                   (null (field decision "tool")) (null (field decision "arguments"))
                   (null (field decision "call_id")) (<= (size decision) 32768))
        (error "Invalid draft decision metadata")))
    (when attempt
      (unless (and (hash-table-p attempt) (= 8 (hash-table-count attempt))
                   (id-p (field attempt "id"))
                   (equal (if decision "decision" "message") (field attempt "kind"))
                   (equal (and decision (field decision "id")) (field attempt "decision_id"))
                   (typep (field attempt "revision") '(integer 0))
                   (<= (field attempt "revision") (field record "revision"))
                   (valid-digest-p (field attempt "digest"))
                   (text-p (field attempt "text") 65536)
                   (equal (disk:text-digest (field attempt "text")) (field attempt "digest"))
                   (member (field attempt "status") '("prepared" "accepted" "rejected" "unknown") :test #'equal)
                   (if (equal "accepted" (field attempt "status"))
                       (if decision (eq t (field attempt "result")) (id-p (field attempt "result")))
                       (null (field attempt "result"))))
        (error "Invalid draft submission metadata"))))
  (unless (<= (reserved-size record) +maximum-record-bytes+) (error "Agent draft exceeds its encoded size limit"))
  record)

(defun new-record (session text point revision)
  "Construct detached metadata from a cached session; no filesystem access."
  (let ((snapshot (agent:session-snapshot session)))
    (agent:json-object "version" 1 "id" (disk:new-id) "session_id" (agent:session-id session)
                       "root" (field snapshot "root") "provider" (field snapshot "provider")
                       "model" (field snapshot "model") "text" text "point" point
                       "revision" revision "decision" nil "attempt" nil)))

(defun store-open-p (store)
  (and store (bt2:with-lock-held ((draft-store-lock store))
               (not (or (draft-store-closing store) (draft-store-failure store))))))
(defun store-error (store)
  (bt2:with-lock-held ((draft-store-lock store)) (draft-store-failure store)))
(defun require-open (store)
  (when (or (draft-store-closing store) (draft-store-failure store))
    (error "Draft storage is closed or its durability is uncertain")))

(defun find-draft (store id)
  "Copy a durable cached checkpoint; no files or editor buffers are opened."
  (unless (id-p id) (error "Invalid draft identity"))
  (bt2:with-lock-held ((draft-store-lock store))
    (let ((record (gethash id (draft-store-records store))))
      (when record (agent:json-copy record)))))
(defun list-drafts (store)
  (bt2:with-lock-held ((draft-store-lock store))
    (sort (loop for record being the hash-values of (draft-store-records store)
                collect (agent:json-copy record)) #'string< :key (lambda (record) (field record "id")))))

(defun reserve-snapshot (store record)
  (let ((id (field record "id")))
    (unless (or (gethash id (draft-store-records store)) (gethash id (draft-store-pending store)))
      (let ((ids (make-hash-table :test 'equal)))
        (maphash (lambda (id value) (declare (ignore value)) (setf (gethash id ids) t)) (draft-store-records store))
        (maphash (lambda (id value) (declare (ignore value)) (setf (gethash id ids) t)) (draft-store-reservations store))
        (when (>= (hash-table-count ids) +maximum-drafts+) (error "Draft capacity is full; explicitly discard an unwanted draft"))))
    (let ((previous (or (gethash id (draft-store-pending store)) (gethash id (draft-store-records store)))))
      (when previous
        (unless (every (lambda (key) (equalp (field previous key) (field record key)))
                       '("session_id" "root" "provider" "model" "decision"))
          (error "Draft identity metadata changed"))
        (when (< (field record "revision") (field previous "revision"))
          (return-from reserve-snapshot))
        (when (and (= (field record "revision") (field previous "revision"))
                   (not (equal (field record "text") (field previous "text"))))
          (error "Draft text changed without a fresh revision"))))
    (setf (gethash id (draft-store-reservations store)) t
          (gethash id (draft-store-pending store)) record)
    (bt2:condition-notify (draft-store-wake store))))

(defun claim-draft (store record &key new)
  "Acquire the sole editor publication claim. NEW is only for a fresh draft UUID."
  (let* ((copy (validate-record (agent:json-copy record))) (id (field copy "id")) (owner (list nil)))
    (bt2:with-lock-held ((draft-store-lock store))
      (require-open store)
      (when (or (gethash id (draft-store-retiring store)) (gethash id (draft-store-owners store))
                (and (not new) (null (gethash id (draft-store-records store)))))
        (error "Draft is already owned, being discarded, or absent"))
      (when (and new (or (gethash id (draft-store-records store)) (gethash id (draft-store-reservations store))))
        (error "New draft identity already exists"))
      (unless new
        (when (or (gethash id (draft-store-reservations store)) (gethash id (draft-store-pending store))
                  (not (equalp copy (gethash id (draft-store-records store)))))
          (error "Draft checkpoint changed or is pending; refresh before restoring")))
      (when new (reserve-snapshot store copy))
      (setf (gethash id (draft-store-owners store)) owner))
    owner))

(defun release-draft (store id owner)
  "Release editor publication authority. Already admitted submissions continue."
  (bt2:with-lock-held ((draft-store-lock store))
    (when (eq owner (gethash id (draft-store-owners store)))
      (remhash id (draft-store-owners store)))))

(defun check-owner (store id owner)
  (unless (and owner (eq owner (gethash id (draft-store-owners store)))
               (not (gethash id (draft-store-retiring store))))
    (error "Draft editor publication claim is no longer live")))

(defun queue-snapshot (store record &key owner)
  "Editor-safe bounded capture. Coalesce edits; a worker owns all disk writes."
  (let ((copy (validate-record (agent:json-copy record))))
    (bt2:with-lock-held ((draft-store-lock store))
      (require-open store) (check-owner store (field copy "id") owner) (reserve-snapshot store copy)))
  (field record "id"))

(defun enqueue (store command &key internal)
  (let ((receipt (agent::make-receipt)))
    (bt2:with-lock-held ((draft-store-lock store))
      (unless internal (require-open store))
      (when (or (draft-store-closed store) (>= (draft-store-queued store) 64))
        (error "Draft command queue is unavailable"))
      (let ((entry (list (cons receipt command))))
        (if (draft-store-tail store) (setf (cdr (draft-store-tail store)) entry)
            (setf (draft-store-queue store) entry))
        (setf (draft-store-tail store) entry)
        (incf (draft-store-queued store))
        (bt2:condition-notify (draft-store-wake store))))
    receipt))

(defun await (receipt)
  (loop (multiple-value-bind (value done) (agent:await-request receipt :timeout 1)
          (when done (return value)))))

(defun write-record (store record)
  ;; The sole store actor owns mutation. Readers only see completed checkpoints.
  (validate-record record)
  (let ((total (reserved-size record)) (id (field record "id")))
    (bt2:with-lock-held ((draft-store-lock store))
      (maphash (lambda (other value) (unless (equal other id) (incf total (reserved-size value))))
               (draft-store-records store)))
    (when (> total +maximum-total-bytes+) (error "Draft storage byte capacity is full"))
    (handler-case (disk:write-private-json (draft-store-directory store) id record :maximum-depth 16)
      (error (condition)
        (bt2:with-lock-held ((draft-store-lock store))
          (setf (draft-store-failure store) (format nil "Draft checkpoint failed (~a); text remains in memory" (type-of condition))))
        (error condition)))
    (bt2:with-lock-held ((draft-store-lock store))
      (setf (gethash id (draft-store-records store)) record)
      (unless (gethash id (draft-store-pending store))
        (remhash id (draft-store-reservations store)))))
  record)

(defun merge-snapshot (store snapshot)
  (let ((previous (find-draft store (field snapshot "id"))))
    (when previous
      (unless (every (lambda (key) (equalp (field previous key) (field snapshot key)))
                     '("session_id" "root" "provider" "model" "decision"))
        (error "Draft identity metadata changed"))
      (when (< (field snapshot "revision") (field previous "revision"))
        (return-from merge-snapshot previous))
      (when (and (= (field snapshot "revision") (field previous "revision"))
                 (not (equal (field snapshot "text") (field previous "text"))))
        (error "Draft text changed without a fresh revision")))
    (let ((candidate (agent:json-copy snapshot)))
      (setf (field candidate "attempt") (and previous (field previous "attempt")))
      candidate)))

(defun receipt-matches-p (attempt receipt)
  (every (lambda (key) (equal (field attempt key) (field receipt key)))
         '("id" "kind" "decision_id" "digest")))

(defun handle-command (store command)
  (destructuring-bind (kind &rest arguments) command
    (ecase kind
      (:prepare
       (destructuring-bind (snapshot attempt) arguments
         (let* ((latest (bt2:with-lock-held ((draft-store-lock store))
                          (let ((pending (gethash (field snapshot "id") (draft-store-pending store))))
                            (if (and pending (> (field pending "revision") (field snapshot "revision")))
                                (agent:json-copy pending) snapshot))))
                (record (merge-snapshot store latest)) (old (field record "attempt")))
           (when (and old (member (field old "status") '("prepared" "unknown") :test #'equal))
             (error "Prior submission acceptance is uncertain; restore the host before submitting"))
           (when (and old (equal "accepted" (field old "status"))
                      (= (field old "revision") (field snapshot "revision")))
             (error "This exact draft revision was already accepted"))
           (setf (field record "attempt") attempt)
           (write-record store record))))
      (:finish
       (destructuring-bind (id attempt-id status result) arguments
         (let* ((record (or (find-draft store id) (error "Draft disappeared during submission")))
                (attempt (field record "attempt")))
           (unless (equal attempt-id (field attempt "id")) (error "Submission identity changed"))
           (setf (field attempt "status") status (field attempt "result") result)
           (write-record store record))))
      (:discard
       (destructuring-bind (id revision acknowledge-uncertainty) arguments
         (when (store-error store) (error "Draft durability is uncertain; restore before discarding"))
         (let ((record (find-draft store id)))
           (when record
             (unless (= revision (field record "revision")) (error "Draft changed; refresh before discarding"))
             (bt2:with-lock-held ((draft-store-lock store))
               (when (or (gethash id (draft-store-owners store)) (gethash id (draft-store-active store))
                         (gethash id (draft-store-pending store)))
                 (error "Draft has pending work; wait for its checkpoint before discarding")))
             (when (and (field record "attempt")
                        (member (field (field record "attempt") "status") '("prepared" "unknown") :test #'equal)
                        (not (and acknowledge-uncertainty (gethash id (draft-store-recovered-unknown store)))))
               (error "Uncertain submission evidence cannot be discarded"))
             ;; Claim admission and retirement share the same lock. No editor
             ;; may acquire publication authority while unlink is in flight.
             (bt2:with-lock-held ((draft-store-lock store))
               (when (or (gethash id (draft-store-owners store)) (gethash id (draft-store-pending store)))
                 (error "Draft acquired an editor owner; close it before discarding"))
               (setf (gethash id (draft-store-retiring store)) t))
             (unwind-protect
                  (progn
                    (handler-case
                        (progn
                          (disk:discard-record (draft-store-directory store) id)
                          ;; Confirm absence even if an earlier unlink or an
                          ;; explicit external cleanup already removed the file.
                          (disk::fsync-directory (draft-store-directory store)))
                      (error (condition)
                        (bt2:with-lock-held ((draft-store-lock store))
                          (setf (draft-store-failure store)
                                (format nil "Draft discard durability failed (~a); restore before retrying" (type-of condition))))
                        (error condition)))
                    (bt2:with-lock-held ((draft-store-lock store))
                      (remhash id (draft-store-records store)) (remhash id (draft-store-recovered-unknown store))))
               (bt2:with-lock-held ((draft-store-lock store)) (remhash id (draft-store-retiring store)))))
           (not (null record))))))))

(defun writer-loop (store)
  (unwind-protect
       (loop
         (let (command snapshot)
           (bt2:with-lock-held ((draft-store-lock store))
             (loop while (and (null (draft-store-queue store)) (zerop (hash-table-count (draft-store-pending store))))
                   do (when (and (draft-store-closing store) (zerop (hash-table-count (draft-store-active store))))
                        (return-from writer-loop))
                      (bt2:condition-wait (draft-store-wake store) (draft-store-lock store)))
             (if (draft-store-queue store)
                 (progn
                   (setf command (pop (draft-store-queue store)))
                   (decf (draft-store-queued store))
                   (unless (draft-store-queue store) (setf (draft-store-tail store) nil)))
                 (maphash (lambda (id value)
                            (unless snapshot
                              (setf snapshot value) (remhash id (draft-store-pending store))))
                          (draft-store-pending store))))
           (handler-case
               (if command (agent::finish-receipt (car command) (handle-command store (cdr command)))
                   (write-record store (merge-snapshot store snapshot)))
             (error (condition)
               (when command (agent::finish-receipt (car command) nil condition))
               (unless command
                 (bt2:with-lock-held ((draft-store-lock store))
                   (setf (draft-store-failure store) (format nil "Draft checkpoint failed (~a); text remains in memory" (type-of condition)))))))))
    (bt2:with-lock-held ((draft-store-lock store))
      (when (draft-store-lease store) (sb-posix:close (draft-store-lease store)) (setf (draft-store-lease store) nil))
      (setf (draft-store-closed store) t))))

(defun submit-draft (store snapshot session &key owner)
  "Worker API. Persist intent before core enqueue; never replay recovered intent.
Closing a view does not cancel this request. Store ownership survives its worker."
  (let* ((snapshot (validate-record (agent:json-copy snapshot)))
         (id (field snapshot "id")) (decision (field snapshot "decision"))
         (attempt (agent:json-object "id" (disk:new-id) "kind" (if decision "decision" "message")
                                    "decision_id" (and decision (field decision "id"))
                                    "revision" (field snapshot "revision") "digest" (disk:text-digest (field snapshot "text"))
                                    "text" (field snapshot "text")
                                    "status" "prepared" "result" nil))
         (receipt (agent::make-receipt)))
    (unless (and (eq session (agent:find-session (draft-store-manager store) (field snapshot "session_id")))
                 (equal (agent:session-id session) (field snapshot "session_id")))
      (error "The exact draft session is unavailable"))
    (bt2:with-lock-held ((draft-store-lock store))
      (require-open store)
      (check-owner store id owner)
      (when (gethash id (draft-store-active store)) (error "Draft submission is already pending"))
      (reserve-snapshot store snapshot)
      (setf (gethash id (draft-store-active store)) t))
    (handler-case
        (bt2:make-thread
         (lambda ()
           (unwind-protect
                (handler-case
                    (progn
                      (await (enqueue store (list :prepare snapshot attempt) :internal t))
                      (let (value failure rejected)
                        (handler-case
                            (setf value
                                  (await (if decision
                                             (agent:resolve-decision session (field decision "id") (field snapshot "text")
                                                                     :submission-id (field attempt "id"))
                                             (agent:submit-message session (field snapshot "text") :submission-id (field attempt "id")))))
                          (error (condition)
                            (setf failure condition)
                            ;; An actor rejection is terminal for this command.
                            ;; Poisoned/uncertain journals refuse the lookup and
                            ;; therefore still require startup reconciliation.
                            (when (typep condition 'agent::request-rejected)
                              (setf rejected
                                    (handler-case (null (agent:find-submission session (field attempt "id")))
                                      (error () nil))))))
                        (await (enqueue store (list :finish id (field attempt "id")
                                                    (cond (rejected "rejected") (failure "unknown") (value "accepted") (t "rejected"))
                                                    (and (not failure) value)) :internal t))
                        (when value
                          ;; The accepted marker is already fsynced. Failure to
                          ;; free the receipt leaves conservative extra evidence.
                          (ignore-errors (await (agent:acknowledge-submission session (field attempt "id")))))
                        (agent::finish-receipt receipt value failure)))
                  (error (condition) (agent::finish-receipt receipt nil condition)))
             (bt2:with-lock-held ((draft-store-lock store))
               (remhash id (draft-store-active store)) (bt2:condition-notify (draft-store-wake store)))))
         :name "agent durable draft submission")
      (error (condition)
        (bt2:with-lock-held ((draft-store-lock store))
          (remhash id (draft-store-active store)) (bt2:condition-notify (draft-store-wake store)))
        (error condition)))
    receipt))

(defun discard-draft (store id &key expected-revision acknowledge-uncertainty)
  (unless (and (id-p id) (typep expected-revision '(integer 0))) (error "Discard needs an exact draft revision"))
  (unless (member acknowledge-uncertainty '(t nil)) (error "Invalid uncertainty acknowledgement"))
  (enqueue store (list :discard id expected-revision acknowledge-uncertainty)))

(defun read-bounded-record (directory id)
  (let ((fd (sb-posix:open (namestring (disk::record-path directory id))
                           (logior sb-posix:o-rdonly sb-posix:o-nofollow sb-posix:o-nonblock))))
    (with-open-stream (input (sb-sys:make-fd-stream fd :input t :element-type '(unsigned-byte 8) :auto-close t))
      (let ((stat (sb-posix:fstat fd)))
        (disk::check-private-file-stat stat id)
        (unless (<= (sb-posix:stat-size stat) +maximum-record-bytes+) (error "Draft file exceeds its read bound"))
        (let ((bytes (make-array (sb-posix:stat-size stat) :element-type '(unsigned-byte 8))))
          (unless (and (= (length bytes) (read-sequence bytes input)) (eq :end (read-byte input nil :end)))
            (error "Draft file changed during bounded read"))
          (let ((text (babel:octets-to-string bytes :encoding :utf-8)))
            (disk::check-json-depth text 16)
            (with-input-from-string (stream text)
              (let ((record (agent:json-copy (yason:parse stream :object-as :hash-table))))
                (unless (and (equal id (field record "id"))
                             (loop for c = (read-char stream nil) while c
                                   always (find c '(#\Space #\Tab #\Newline #\Return))))
                  (error "Invalid draft file identity or trailing data"))
                (validate-record record)))))))))

(defun reconcile-record (store record)
  ;; Startup owns the draft lease, and the prior store retains it until every
  ;; submission worker has stopped. The core manager must already be restored.
  (let ((attempt (field record "attempt")))
    (when attempt
      (let ((session (agent:find-session (draft-store-manager store) (field record "session_id"))))
        (when session (await (agent:session-ready session)))
        (when (member (field attempt "status") '("prepared" "unknown") :test #'equal)
          (let ((receipt (and session (agent:find-submission session (field attempt "id")))))
            (when (and receipt (not (receipt-matches-p attempt receipt))) (error "Draft receipt identity mismatch"))
            (setf (field attempt "status") (cond (receipt "accepted") (session "rejected") (t "unknown"))
                  (field attempt "result") (and receipt (field receipt "result")))
            (write-record store record)))
        (when (and session (equal "accepted" (field attempt "status")))
          (ignore-errors (await (agent:acknowledge-submission session (field attempt "id")))))))))

(defun open-store (&key directory manager)
  "Blocking startup API, after the core manager has restored its sessions."
  (unless (and directory (uiop:absolute-pathname-p directory) (agent:manager-open-p manager))
    (error "Draft storage needs an absolute private directory and restored agent manager"))
  (let* ((directory (uiop:ensure-directory-pathname directory))
         (store (%make-store :directory directory :manager manager :lease (agent::acquire-lease directory))))
    (handler-case
        (progn
          (let ((stream (sb-posix:opendir (namestring directory))) (count 0) (total 0))
            (unwind-protect
                 (loop for entry = (sb-posix:readdir stream) until (sb-alien:null-alien entry)
                       for name = (sb-posix:dirent-name entry)
                       do (when (> (incf count) 128) (error "Draft namespace has too many entries"))
                          (when (and (> (length name) 5) (equal ".json" (subseq name (- (length name) 5))))
                            (let* ((id (subseq name 0 (- (length name) 5))) (record (read-bounded-record directory id)))
                              (when (or (>= (hash-table-count (draft-store-records store)) +maximum-drafts+)
                                        (> (incf total (reserved-size record)) +maximum-total-bytes+))
                                (error "Draft namespace exceeds its retention limits"))
                              (setf (gethash id (draft-store-records store)) record))))
              (sb-posix:closedir stream)))
          (dolist (record (list-drafts store))
            (reconcile-record store record)
            (when (and (field record "attempt") (equal "unknown" (field (field record "attempt") "status")))
              (setf (gethash (field record "id") (draft-store-recovered-unknown store)) t)))
          (setf (draft-store-worker store) (bt2:make-thread (lambda () (writer-loop store)) :name "agent draft checkpoints"))
          store)
      (error (condition)
        (when (draft-store-lease store) (sb-posix:close (draft-store-lease store)))
        (error condition)))))

(defun close-store (store &key wait)
  "Drain snapshots and registered submissions before releasing directory ownership.
WAIT belongs on a shutdown worker; this never interrupts or resubmits agent work."
  (bt2:with-lock-held ((draft-store-lock store))
    (setf (draft-store-closing store) t) (bt2:condition-notify (draft-store-wake store)))
  (when wait (bt2:join-thread (draft-store-worker store)))
  store)
