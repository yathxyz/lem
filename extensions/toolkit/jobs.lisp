(defpackage :lem-toolkit/jobs
  (:use :cl)
  (:local-nicknames (:store :lem-daemon/recovery-store) (:wire :lem-toolkit/jobs-wire))
  (:export :open-job-manager :close-job-manager :start-job :cancel-job :wait-job
           :inspect-job-journal :job-manager-ready-p :job-manager-status
           :list-job-journal :inspect-job-record :discard-job
           :list-jobs :find-job :job-id :job-owner :job-directory :job-snapshot :job-result :job-output-octets
           :*guardian-program* :*guardian-path* :*default-manager*))
(in-package :lem-toolkit/jobs)

(defvar *guardian-program* nil)
(defvar *guardian-path* nil)
(defvar *default-manager* nil)
(defconstant +fd-cloexec+ 1) ; Linux FD_CLOEXEC is not exported by SB-POSIX.
(defconstant +default-maximum-jobs+ 256)
(defconstant +maximum-output-limit+ (* 1024 1024))
(defparameter +terminal-states+ '("exited" "signaled" "cancelled" "timed-out" "failed" "interrupted"))

(sb-alien:define-alien-routine ("flock" %flock) sb-alien:int
  (fd sb-alien:int) (operation sb-alien:int))

(defstruct ring
  (bytes #() :type vector) (start 0) (length 0) (total 0))
(defun new-ring (capacity) (make-ring :bytes (make-array capacity :element-type '(unsigned-byte 8))))
(defun ring-append (ring bytes)
  (let* ((capacity (length (ring-bytes ring))) (n (length bytes)))
    (incf (ring-total ring) n)
    (cond ((>= n capacity)
           (replace (ring-bytes ring) bytes :start2 (- n capacity))
           (setf (ring-start ring) 0 (ring-length ring) capacity))
          (t
           (let* ((end (mod (+ (ring-start ring) (ring-length ring)) capacity))
                  (first (min n (- capacity end))))
             (replace (ring-bytes ring) bytes :start1 end :end2 first)
             (replace (ring-bytes ring) bytes :start2 first :end1 (- n first))
             (when (> (+ (ring-length ring) n) capacity)
               (setf (ring-start ring) (mod (+ (ring-start ring) (- (+ (ring-length ring) n) capacity)) capacity)))
             (setf (ring-length ring) (min capacity (+ (ring-length ring) n))))))))
(defun ring-copy (ring)
  (let* ((bytes (make-array (ring-length ring) :element-type '(unsigned-byte 8)))
         (first (min (ring-length ring) (- (length (ring-bytes ring)) (ring-start ring)))))
    (replace bytes (ring-bytes ring) :start2 (ring-start ring) :end1 first)
    (replace bytes (ring-bytes ring) :start1 first :end2 (- (ring-length ring) first))
    bytes))
(defun ring-text (ring) (babel:octets-to-string (ring-copy ring) :encoding :utf-8 :errorp nil))

(defstruct (job-manager (:conc-name manager-))
  directory lease directory-identity
  (maximum-jobs +default-maximum-jobs+) (count 0) (unloaded 0) (ignored 0)
  (diagnostics nil) pending-deletion
  (maintenance-lock (bt2:make-lock :name "Lisp job journal maintenance"))
  (jobs (make-hash-table :test #'equal))
  (lock (bt2:make-lock :name "Lisp job registry"))
  (closed nil))

(defstruct (job (:conc-name %job-))
  id owner argv directory manager
  (state "queued") (reason nil) (exit-code nil) (started 0) (finished 0)
  stdout stderr timeout-ms output-limit
  guardian-program guardian-path environment environment-p input on-output
  (done nil) (retired nil)
  (lock (bt2:make-lock :name "Lisp managed job"))
  thread (cancel-requested nil) (journal-error nil))

(defun job-id (job) (copy-seq (%job-id job)))
(defun job-owner (job) (copy-seq (%job-owner job)))
(defun job-directory (job) (copy-seq (%job-directory job)))
(defun terminal-p (job) (member (%job-state job) +terminal-states+ :test #'equal))

(defun job-snapshot-unlocked (job &key (include-output t))
  (let ((record (store:object
   "version" 1 "id" (%job-id job) "owner" (%job-owner job)
   "argv" (coerce (mapcar #'copy-seq (%job-argv job)) 'vector)
   "directory" (%job-directory job) "state" (%job-state job)
   "reason" (%job-reason job) "exit-code" (%job-exit-code job)
   "started" (%job-started job) "finished" (%job-finished job)
   "daemon-failure-policy" "terminate-on-disconnect; never-replay"
   "timeout-ms" (%job-timeout-ms job) "output-limit" (%job-output-limit job)
   "stdout-bytes" (ring-total (%job-stdout job)) "stderr-bytes" (ring-total (%job-stderr job))
   "stdout-retained-bytes" (ring-length (%job-stdout job))
   "stderr-retained-bytes" (ring-length (%job-stderr job))
   "journal-error" (%job-journal-error job))))
    (when include-output
      (setf (gethash "stdout" record) (ring-text (%job-stdout job))
            (gethash "stderr" record) (ring-text (%job-stderr job))))
    (maphash (lambda (key value)
               (when (stringp value) (setf (gethash key record) (copy-seq value)))) record)
    record))

(defun job-snapshot (job &key (include-output t))
  "Return a detached JSON-compatible snapshot. This never waits for process or disk I/O."
  (bt2:with-lock-held ((%job-lock job)) (job-snapshot-unlocked job :include-output include-output)))
(defun job-result (job)
  (bt2:with-lock-held ((%job-lock job))
    (when (and (terminal-p job) (%job-done job)) (job-snapshot-unlocked job))))
(defun job-output-octets (job &optional (channel :stdout))
  "Return retained raw bytes and total byte count. Text snapshots replace malformed UTF-8."
  (bt2:with-lock-held ((%job-lock job))
    (let ((ring (ecase channel (:stdout (%job-stdout job)) (:stderr (%job-stderr job)))))
      (values (ring-copy ring) (ring-total ring)))))

(defun bounded-string-p (value maximum)
  (and (stringp value) (<= (length value) maximum) (not (find #\Null value))))
(defun valid-argv-p (argv)
  (and (listp argv) (<= 1 (length argv) 128)
       (every (lambda (s) (bounded-string-p s 65536)) argv)
       (plusp (length (first argv)))))

(defun valid-environment-p (environment)
  (and (listp environment) (<= (length environment) 4096)
       (loop with total = 0 for entry in environment
             always (and (bounded-string-p entry 65536)
                         (let ((equal (position #\= entry))) (and equal (plusp equal)))
                         (<= (incf total (length (wire:utf8 entry))) (* 1024 1024))))))

(defun validate-journal (record id)
  (unless (and (hash-table-p record) (= (hash-table-count record) 20)
               (loop for key being the hash-keys of record
                     always (member key '("version" "id" "owner" "argv" "directory" "state"
                                          "reason" "exit-code" "started" "finished" "daemon-failure-policy"
                                          "timeout-ms" "output-limit" "stdout-hex" "stderr-hex"
                                          "stdout-bytes" "stderr-bytes" "stdout-retained-bytes"
                                          "stderr-retained-bytes" "journal-error") :test #'equal))
               (eql 1 (store:field record "version")) (equal id (store:field record "id"))
               (bounded-string-p (store:field record "owner") 256)
               (or (listp (store:field record "argv")) (vectorp (store:field record "argv")))
               (valid-argv-p (coerce (store:field record "argv") 'list))
               (bounded-string-p (store:field record "directory") 65536)
               (uiop:absolute-pathname-p (store:field record "directory"))
               (member (store:field record "state") (append '("queued" "running") +terminal-states+) :test #'equal)
               (equal "terminate-on-disconnect; never-replay" (store:field record "daemon-failure-policy"))
               (typep (store:field record "output-limit") `(integer 1 ,+maximum-output-limit+))
               (typep (store:field record "timeout-ms") '(integer 1 86400000))
               (every (lambda (key) (typep (store:field record key) '(integer 0)))
                      '("started" "finished" "stdout-bytes" "stderr-bytes" "stdout-retained-bytes" "stderr-retained-bytes"))
               (every (lambda (key) (or (null (store:field record key))
                                        (bounded-string-p (store:field record key) 65536)))
                      '("reason" "journal-error"))
               (or (null (store:field record "exit-code"))
                   (typep (store:field record "exit-code") '(integer 0 255)))
               (every (lambda (key)
                        (let ((hex (store:field record key)))
                          (and (stringp hex) (evenp (length hex))
                               (<= (length hex) (* 2 (store:field record "output-limit")))
                               (every (lambda (c) (find c "0123456789abcdef")) hex))))
                      '("stdout-hex" "stderr-hex"))
               (loop for channel in '("stdout" "stderr")
                     for retained = (store:field record (concatenate 'string channel "-retained-bytes"))
                     always (and (= (* 2 retained) (length (store:field record (concatenate 'string channel "-hex"))))
                                 (<= retained (store:field record (concatenate 'string channel "-bytes"))))))
    (error "Invalid managed job journal: ~a" id))
  record)

(defun job-journal (job)
  (bt2:with-lock-held ((%job-lock job))
    (let ((record (job-snapshot-unlocked job :include-output nil)))
      (setf (gethash "stdout-hex" record) (ironclad:byte-array-to-hex-string (ring-copy (%job-stdout job)))
            (gethash "stderr-hex" record) (ironclad:byte-array-to-hex-string (ring-copy (%job-stderr job))))
      record)))

(defun persist-job (job)
  (bt2:with-lock-held ((%job-lock job))
    (when (or (%job-retired job) (null (manager-lease (%job-manager job))))
      (error "Job no longer owns a journal writer")))
  (handler-case
      (progn
        (store:write-private-json (manager-directory (%job-manager job)) (%job-id job) (job-journal job))
        (bt2:with-lock-held ((%job-lock job)) (setf (%job-journal-error job) nil)))
    (error (condition)
      (bt2:with-lock-held ((%job-lock job)) (setf (%job-journal-error job) (princ-to-string condition)))
      (error condition))))

(defun acquire-lease (directory)
  (store:ensure-private-directory directory)
  (let* ((path (merge-pathnames ".manager.lock" directory))
         (fd (sb-posix:open (namestring path) (logior sb-posix:o-rdwr sb-posix:o-creat sb-posix:o-nofollow) #o600)))
    (handler-case
        (progn
          (store::check-private-file-stat (sb-posix:fstat fd) path)
          (unless (zerop (%flock fd 6)) (error "A job manager already owns ~a" directory))
          (sb-posix:fcntl fd sb-posix:f-setfd +fd-cloexec+)
          fd)
      (error (condition) (sb-posix:close fd) (error condition)))))

(defun historical-job (manager record)
  (let* ((capacity (store:field record "output-limit"))
         (job (make-job :id (store:field record "id") :owner (store:field record "owner")
                        :argv (coerce (store:field record "argv") 'list)
                        :directory (store:field record "directory") :manager manager
                        :done t :state (store:field record "state") :reason (store:field record "reason")
                        :journal-error (store:field record "journal-error")
                        :exit-code (store:field record "exit-code")
                        :started (store:field record "started") :finished (store:field record "finished")
                        :timeout-ms (store:field record "timeout-ms") :output-limit capacity
                        :stdout (new-ring capacity) :stderr (new-ring capacity))))
    (ring-append (%job-stdout job) (ironclad:hex-string-to-byte-array (store:field record "stdout-hex")))
    (ring-append (%job-stderr job) (ironclad:hex-string-to-byte-array (store:field record "stderr-hex")))
    (setf (ring-total (%job-stdout job)) (store:field record "stdout-bytes")
          (ring-total (%job-stderr job)) (store:field record "stderr-bytes"))
    (unless (terminal-p job)
      (setf (%job-state job) "interrupted" (%job-finished job) (get-universal-time)
            (%job-reason job) "Previous controller unavailable; external actions were not replayed")
      (persist-job job))
    job))

(defun journal-directory (directory name)
  (uiop:ensure-directory-pathname
   (or directory (merge-pathnames "jobs/" (store:default-directory name)))))

(defun journal-page-ids (directory after limit &optional extra-ids)
  (unless (and (or (null after) (store::valid-id-p after))
               (typep limit '(integer 1 64)))
    (error "Invalid job journal page"))
  (let ((ids nil) (total 0) (ignored 0) (remaining 0) (missing (make-hash-table :test #'equal)))
    (dolist (id extra-ids) (setf (gethash id missing) t))
    (flet ((consider (id)
             (when (or (null after) (string< after id))
               (incf remaining)
               (when (or (< (length ids) limit) (string< id (car (last ids))))
                 (setf ids (sort (cons id ids) #'string<))
                 (when (> (length ids) limit) (setf ids (subseq ids 0 limit)))))))
      (store:map-private-json
       directory (lambda (id path)
                   (declare (ignore path))
                   (cond ((not (store::valid-id-p id)) (incf ignored))
                         (t (incf total) (remhash id missing) (consider id)))))
      ;; Only the already bounded registry/pending receipt contributes absent IDs;
      ;; disk enumeration never accumulates an unbounded name catalog.
      (maphash (lambda (id value) (declare (ignore value)) (consider id)) missing))
    (values ids (store:object "total" total "ignored-names" ignored
                             "reserved-without-journal" (hash-table-count missing)
                             "next-after" (when (> remaining (length ids)) (car (last ids)))
                             "truncated" (if (> remaining (length ids)) t yason:false)))))

(defun inspect-disk-job (directory id)
  (handler-case
      (multiple-value-bind (record fingerprint diagnostic) (store:inspect-private-json directory id)
        (unless diagnostic
          (handler-case (validate-journal record id)
            (error () (setf diagnostic "invalid-job-schema" record nil))))
        (store:object "id" (copy-seq id) "record" record "fingerprint" fingerprint
                      "diagnostic" diagnostic))
    (error (condition)
      (store:object "id" (copy-seq id) "record" nil "fingerprint" nil
                    "diagnostic" (princ-to-string (type-of condition))))))

(defun inspect-job-journal (&key directory (name "server") after (limit 64))
  "Read one bounded page without a lease or writes. Return records, failures, page metadata.
Running records are historical observations, never proof of current process ownership."
  (let ((directory (journal-directory directory name)) (records nil) (failures nil))
    (multiple-value-bind (ids page) (journal-page-ids directory after limit)
      (dolist (id ids)
        (let ((entry (inspect-disk-job directory id)))
          (if (store:field entry "diagnostic")
              (push (cons (store::record-path directory id) (store:field entry "diagnostic")) failures)
              (push (store:field entry "record") records))))
      (values (nreverse records) (nreverse failures) page))))

(defun directory-identity (directory)
  (let ((stat (sb-posix:stat (uiop:native-namestring directory))))
    (cons (sb-posix:stat-dev stat) (sb-posix:stat-ino stat))))

(defun check-manager-ownership (manager)
  ;; Called under the maintenance lock, never under the short registry lock.
  (when (or (manager-closed manager) (null (manager-lease manager)))
    (error "Job manager is closed"))
  (store:ensure-private-directory (manager-directory manager) :create nil)
  (unless (equal (manager-directory-identity manager) (directory-identity (manager-directory manager)))
    (error "Job journal namespace was replaced")))

(defun open-job-manager (&key directory (name "server") (maximum-jobs +default-maximum-jobs+))
  "Blocking setup: examine at most MAXIMUM-JOBS records, preserve overflow without replay.
Corrupt records leave a usable inspection manager with admission blocked until explicit cleanup."
  (unless (typep maximum-jobs '(integer 1 4096)) (error "Invalid managed job capacity"))
  (let* ((directory (journal-directory directory name))
         (manager (make-job-manager :directory directory :lease (acquire-lease directory)
                                    :maximum-jobs maximum-jobs)))
    (handler-case
        (progn
          (setf (manager-directory-identity manager) (directory-identity directory))
          (let ((examined 0))
            (store:map-private-json
             directory
             (lambda (id path)
               (declare (ignore path))
               (cond ((not (store::valid-id-p id)) (incf (manager-ignored manager)))
                     (t (incf (manager-count manager))
                        (when (< examined maximum-jobs)
                          (incf examined)
                          (handler-case
                              (let* ((record (validate-journal (store:read-private-json directory id) id))
                                     (job (historical-job manager record)))
                                (setf (gethash id (manager-jobs manager)) job))
                            (error (condition)
                              (when (< (length (manager-diagnostics manager)) 16)
                                (push (cons id (princ-to-string (type-of condition)))
                                      (manager-diagnostics manager)))))))))))
          (setf (manager-unloaded manager) (- (manager-count manager) (hash-table-count (manager-jobs manager))))
          manager)
      (error (condition) (sb-posix:close (manager-lease manager)) (error condition)))))

(defun admission-ready-p (manager)
  (and (not (manager-closed manager)) (zerop (manager-unloaded manager))
       (null (manager-pending-deletion manager)) (< (manager-count manager) (manager-maximum-jobs manager))))

(defun job-manager-status (&optional (manager *default-manager*))
  "Copied bounded cached capacity metadata; no disk I/O. Counts include reserved unwritten jobs."
  (unless manager (error "No managed job registry is open"))
  (bt2:with-lock-held ((manager-lock manager))
    (store:object "maximum-jobs" (manager-maximum-jobs manager) "retained-slots" (manager-count manager)
                  "loaded" (hash-table-count (manager-jobs manager)) "unloaded" (manager-unloaded manager)
                  "ignored-names" (manager-ignored manager) "open" (if (manager-closed manager) yason:false t)
                  "admission-ready" (if (admission-ready-p manager) t yason:false)
                  "pending-deletion" (when (manager-pending-deletion manager)
                                       (store:object "id" (copy-seq (car (manager-pending-deletion manager)))
                                                     "fingerprint" (copy-seq (cdr (manager-pending-deletion manager)))))
                  "diagnostics" (coerce (mapcar (lambda (entry)
                                                  (store:object "id" (copy-seq (car entry))
                                                                "diagnostic" (copy-seq (cdr entry))))
                                                (manager-diagnostics manager)) 'vector))))

(defun inspect-manager-job (manager id)
  (unless (store::valid-id-p id) (error "Invalid managed job identifier"))
  (let ((job (find-job id manager)))
    (if (and job (null (store::path-stat (store::record-path (manager-directory manager) id))))
        (store:object "id" (copy-seq id) "record" nil "fingerprint" "missing" "diagnostic" "missing")
        (inspect-disk-job (manager-directory manager) id))))

(defun inspect-job-record (manager id)
  "Blocking exact-ID disk inspection under live manager ownership; returns detached data."
  (bt2:with-lock-held ((manager-maintenance-lock manager))
    (check-manager-ownership manager)
    (inspect-manager-job manager id)))

(defun list-job-journal (manager &key after (limit 64))
  "Blocking paginated disk inventory. Output tails/argv are available via exact inspection."
  (bt2:with-lock-held ((manager-maintenance-lock manager))
    (check-manager-ownership manager)
    (multiple-value-bind (ids page)
        (journal-page-ids (manager-directory manager) after limit
                          (append (mapcar #'job-id (list-jobs manager))
                                  (when (manager-pending-deletion manager)
                                    (list (car (manager-pending-deletion manager))))))
      (setf (gethash "entries" page)
            (coerce (mapcar (lambda (id)
                              (let* ((entry (inspect-manager-job manager id))
                                     (record (store:field entry "record")))
                                (remhash "record" entry)
                                (setf (gethash "loaded" entry) (if (find-job id manager) t yason:false))
                                (dolist (key '("state" "owner" "started" "finished" "exit-code"))
                                  (setf (gethash key entry) (when record (store:field record key))))
                                entry)) ids) 'vector))
      page)))

(defun job-settled-p (job)
  (and (bt2:with-lock-held ((%job-lock job)) (and (%job-done job) (terminal-p job)))
       (or (null (%job-thread job)) (not (bt2:thread-alive-p (%job-thread job))))))

(defun uncertain-journal-p (entry job)
  (let ((record (store:field entry "record")))
    (or (store:field entry "diagnostic")
        (not (member (store:field record "state") '("exited" "signaled" "cancelled" "timed-out") :test #'equal))
        (store:field record "journal-error")
        (and job (bt2:with-lock-held ((%job-lock job)) (%job-journal-error job))))))

(defun discard-job (manager id &key expected-fingerprint acknowledge-uncertain)
  "Blocking explicit cleanup. Refuse active writers, stale review or unacknowledged uncertainty.
A failed unlink/fsync retains one pending receipt; retry that exact receipt before other cleanup."
  (unless (and (store::valid-id-p id) (stringp expected-fingerprint)
               (or (equal expected-fingerprint "missing")
                   (and (= 64 (length expected-fingerprint))
                        (every (lambda (c) (find c "0123456789abcdef")) expected-fingerprint))))
    (error "Cleanup requires an exact reviewed job fingerprint"))
  (bt2:with-lock-held ((manager-maintenance-lock manager))
    (check-manager-ownership manager)
    (let* ((job (find-job id manager)) (pending (manager-pending-deletion manager))
           (path (store::record-path (manager-directory manager) id)))
      (when (and pending (not (and (equal id (car pending)) (equal expected-fingerprint (cdr pending)))))
        (error "Resolve the pending job deletion before other cleanup"))
      (when (and job (not (job-settled-p job))) (error "Job controller or process cleanup is still active"))
      (unless (or job pending (store::path-stat path)) (return-from discard-job nil))
      (let ((entry (unless (and pending (null (store::path-stat path))) (inspect-manager-job manager id))))
        (when entry
          (unless (equal expected-fingerprint (store:field entry "fingerprint"))
            (error "Job journal changed or cannot be safely fingerprinted"))
          (when (and (uncertain-journal-p entry job) (not acknowledge-uncertain))
            (error "Explicit acknowledgment of uncertain job history is required")))
        (when (and pending (not acknowledge-uncertain))
          (error "Explicit acknowledgment of uncertain deletion durability is required"))
        ;; Keep the slot until the directory sync confirms absence. No controller
        ;; is alive to recreate a loaded job; unloaded records have no writer.
        (bt2:with-lock-held ((manager-lock manager))
          (setf (manager-pending-deletion manager) (cons (copy-seq id) (copy-seq expected-fingerprint))))
        ;; An absent-file retry still needs a directory sync; successful unlink
        ;; already performs it inside the shared store.
        (unless (store:discard-record (manager-directory manager) id)
          (store::fsync-directory (manager-directory manager)))
        (when job (bt2:with-lock-held ((%job-lock job)) (setf (%job-retired job) t)))
        (bt2:with-lock-held ((manager-lock manager))
          (remhash id (manager-jobs manager))
          (decf (manager-count manager))
          (unless job (decf (manager-unloaded manager)))
          (setf (manager-diagnostics manager) (remove id (manager-diagnostics manager) :key #'car :test #'equal)
                (manager-pending-deletion manager) nil))
        t))))

(defun list-jobs (&optional (manager *default-manager*))
  (unless manager (error "No managed job registry is open"))
  (bt2:with-lock-held ((manager-lock manager))
    (loop for job being the hash-values of (manager-jobs manager) collect job)))
(defun job-manager-ready-p (&optional (manager *default-manager*))
  "True for a fully opened manager that has not begun closing. No I/O is performed."
  (and (job-manager-p manager)
       (bt2:with-lock-held ((manager-lock manager)) (not (manager-closed manager)))))
(defun find-job (id &optional (manager *default-manager*))
  (unless manager (error "No managed job registry is open"))
  (bt2:with-lock-held ((manager-lock manager)) (gethash id (manager-jobs manager))))

(defun start-job (argv &key (manager *default-manager*) (owner "human")
                        (directory (uiop:native-namestring (uiop:getcwd)))
                        (timeout 300) (output-limit (* 64 1024))
                        (environment nil environment-p) input on-output)
  "Queue argv literally, returning without launch, stream or filesystem I/O.
No implicit shell. OWNER labels the caller; authorization belongs to the calling UI/agent."
  (unless manager (error "No managed job registry is open"))
  (unless environment-p (setf environment (sb-ext:posix-environ)))
  (unless (and (valid-argv-p argv) (bounded-string-p owner 256)
               (bounded-string-p directory 65536) (uiop:absolute-pathname-p directory)
               (or (null input) (stringp input) (typep input '(vector (unsigned-byte 8))))
               (or (null on-output) (functionp on-output))
               (realp timeout) (<= 0.001 timeout 86400)
               (typep output-limit `(integer 1 ,+maximum-output-limit+))
               (valid-environment-p environment))
    (error "Invalid managed job launch arguments"))
  (let* ((input (cond ((null input) #()) ((stringp input) (wire:utf8 input)) (t (copy-seq input))))
         (job (make-job :id (store:new-id) :owner (copy-seq owner) :argv (mapcar #'copy-seq argv)
                       :directory (copy-seq directory) :manager manager
                       :timeout-ms (ceiling (* timeout 1000)) :output-limit output-limit
                       :stdout (new-ring output-limit) :stderr (new-ring output-limit)
                       :environment (mapcar #'copy-seq environment) :environment-p environment-p
                       :input input :on-output on-output
                       :guardian-program (or *guardian-program* (uiop:getenvp "LEM_TOOLKIT_SBCL"))
                       :guardian-path (or *guardian-path* (uiop:getenvp "LEM_TOOLKIT_GUARDIAN")
                                          (asdf:system-relative-pathname "lem-toolkit/jobs" "guardian.lisp")))))
    (when (> (length input) (* 1024 1024)) (error "Managed job stdin exceeds 1 MiB"))
    (bt2:with-lock-held ((manager-lock manager))
      (unless (admission-ready-p manager)
        (error "Managed job capacity unavailable; inspect status and explicitly clean retained history"))
      (incf (manager-count manager))
      (setf (gethash (%job-id job) (manager-jobs manager)) job)
      (handler-case
          (setf (%job-thread job) (bt2:make-thread (lambda () (control-job job))
                                                 :name (format nil "Lisp job ~a" (%job-id job))))
        (error (condition)
          (remhash (%job-id job) (manager-jobs manager)) (decf (manager-count manager))
          (error condition))))
    job))

(defun cancel-job (job)
  "Request cancellation without waiting or signalling a numeric PID."
  (bt2:with-lock-held ((%job-lock job))
    (unless (terminal-p job) (setf (%job-cancel-requested job) t))))

(defun wait-job (job &key timeout)
  "Explicit blocking API for REPL/workers/tests; returns NIL on caller wait timeout."
  (let ((deadline (when timeout (+ (get-internal-real-time) (* timeout internal-time-units-per-second)))))
    (loop for result = (job-result job)
          when result return result
          when (and deadline (>= (get-internal-real-time) deadline)) return nil
          do (sleep 0.01))))

(defun set-state (job state &optional reason exit-code)
  (bt2:with-lock-held ((%job-lock job))
    (setf (%job-state job) state (%job-reason job) reason (%job-exit-code job) exit-code)
    (when (equal state "running") (setf (%job-started job) (get-universal-time)))
    (when (member state +terminal-states+ :test #'equal) (setf (%job-finished job) (get-universal-time)))))

(defun binary-copy-stream (stream direction)
  (let ((fd (sb-posix:dup (sb-sys:fd-stream-fd stream))))
    (sb-posix:fcntl fd sb-posix:f-setfd +fd-cloexec+)
    (sb-sys:make-fd-stream fd :input (eq direction :input) :output (eq direction :output)
                             :element-type '(unsigned-byte 8) :buffering :none :auto-close t)))

(defun parse-final-frame (payload)
  (let* ((text (wire:text payload)) (space (position #\Space text)))
    (unless space (error "Malformed guardian result"))
    (let ((state (subseq text 0 space)) (code (parse-integer text :start (1+ space))))
      (unless (and (member state +terminal-states+ :test #'equal) (<= 0 code 255))
        (error "Invalid guardian result"))
      (values state code))))

(defun control-job (job)
  (let ((process nil) (input nil) (output nil) (cancel-sent nil) (final-state nil) (final-code nil)
        (diagnostic nil))
    (unwind-protect
         (handler-case
             (progn
               ;; Durable intent must precede any external effect.
               (persist-job job)
               (when (bt2:with-lock-held ((%job-lock job)) (%job-cancel-requested job))
                 (set-state job "cancelled" "Cancelled before launch")
                 (persist-job job)
                 (return-from control-job))
               (unless (and (%job-guardian-program job)
                            (uiop:absolute-pathname-p (%job-guardian-program job)))
                 (error "Set LEM_TOOLKIT_SBCL to the absolute stock SBCL executable"))
               (setf process
                     (sb-ext:run-program (%job-guardian-program job)
                            (list "--noinform" "--no-sysinit" "--no-userinit" "--disable-debugger"
                                  "--script" (uiop:native-namestring (%job-guardian-path job)))
                            :search nil :wait nil :input :stream :output :stream :error nil
                            :environment '("LANG=C.UTF-8" "LC_ALL=C.UTF-8"))
                     input (binary-copy-stream (sb-ext:process-input process) :output)
                     output (binary-copy-stream (sb-ext:process-output process) :input))
               ;; Retain only the binary copies. Closing the controller's last input
               ;; descriptor is the guardian's ownership signal on failures.
               (close (sb-ext:process-input process))
               (close (sb-ext:process-output process))
               (wire:write-frame #\L (wire:encode-launch (%job-argv job) (%job-directory job)
                                                        (%job-timeout-ms job) (%job-input job)
                                                        (%job-environment job)) input)
               (setf (%job-input job) nil)
               (loop
                 (when (and (not final-state) (not cancel-sent)
                            (bt2:with-lock-held ((%job-lock job)) (%job-cancel-requested job)))
                   (write-byte (char-code #\K) input) (finish-output input) (setf cancel-sent t))
                 (when (or (listen output) (sb-sys:wait-until-fd-usable (sb-sys:fd-stream-fd output) :input 0.05 nil))
                   (multiple-value-bind (tag payload) (wire:read-frame output)
                     (unless tag (return))
                     (when final-state (error "Guardian sent data after final result"))
                     (case tag
                       ((#\O #\E)
                        (when (> (length payload) 4096) (error "Guardian output chunk exceeds 4096 bytes"))
                        (bt2:with-lock-held ((%job-lock job))
                          (ring-append (if (char= tag #\O) (%job-stdout job) (%job-stderr job)) payload))
                        (when (%job-on-output job)
                          (handler-case
                              (funcall (%job-on-output job) job (if (char= tag #\O) :stdout :stderr)
                                       (copy-seq payload))
                            (error () (error "Managed job output consumer failed")))))
                       (#\R (set-state job "running") (persist-job job))
                       (#\F (let ((text (wire:text payload)))
                              (setf diagnostic (subseq text 0 (min 4096 (length text))))))
                       (#\X (multiple-value-setq (final-state final-code) (parse-final-frame payload)))
                       (t (error "Unknown guardian frame"))))))
               (sb-ext:process-wait process)
               (unless final-state (error "Guardian closed without a final result; execution outcome is uncertain"))
               (set-state job final-state diagnostic final-code)
               (persist-job job))
           (error (condition)
             (when input (ignore-errors (close input)))
             (when output (ignore-errors (close output)))
             (set-state job "failed" (princ-to-string condition))
             (ignore-errors (persist-job job))))
      (when input (ignore-errors (close input)))
      (when output (ignore-errors (close output)))
      (when process
        ;; Closing the control pipe makes the live guardian kill its own group.
        ;; Never fall back to a journal PID or PGID after an uncertain failure.
        (ignore-errors (sb-ext:process-wait process))
        (ignore-errors (sb-ext:process-close process)))
      (setf (%job-input job) nil (%job-environment job) nil (%job-on-output job) nil)
      (bt2:with-lock-held ((%job-lock job)) (setf (%job-done job) t)))))

(defun close-job-manager (&optional (manager *default-manager*))
  "Blocking teardown: cancel/join all controllers before releasing the maintenance lease."
  (when manager
    (bt2:with-lock-held ((manager-maintenance-lock manager))
      (bt2:with-lock-held ((manager-lock manager)) (setf (manager-closed manager) t))
      (dolist (job (list-jobs manager)) (cancel-job job))
      (dolist (job (list-jobs manager))
        (when (%job-thread job) (bt2:join-thread (%job-thread job))))
      (when (manager-lease manager) (sb-posix:close (manager-lease manager)) (setf (manager-lease manager) nil))))
  t)
