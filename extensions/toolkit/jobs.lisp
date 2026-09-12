(defpackage :lem-toolkit/jobs
  (:use :cl)
  (:local-nicknames (:store :lem-daemon/recovery-store) (:wire :lem-toolkit/jobs-wire))
  (:export :open-job-manager :close-job-manager :start-job :cancel-job :wait-job
           :inspect-job-journal :job-manager-ready-p
           :list-jobs :find-job :job-id :job-owner :job-directory :job-snapshot :job-result :job-output-octets
           :*guardian-program* :*guardian-path* :*default-manager*))
(in-package :lem-toolkit/jobs)

(defvar *guardian-program* nil)
(defvar *guardian-path* nil)
(defvar *default-manager* nil)
(defconstant +fd-cloexec+ 1) ; Linux FD_CLOEXEC is not exported by SB-POSIX.
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
  directory lease
  (jobs (make-hash-table :test #'equal))
  (lock (bt2:make-lock :name "Lisp job registry"))
  (closed nil))

(defstruct (job (:conc-name %job-))
  id owner argv directory manager
  (state "queued") (reason nil) (exit-code nil) (started 0) (finished 0)
  stdout stderr timeout-ms output-limit
  guardian-program guardian-path environment environment-p input on-output
  (done nil)
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

(defun inspect-job-journal (&key directory (name "server"))
  "Read validated records and return (pathname . diagnostic) failures separately.
No editor, manager lease, reconciliation, process launch or journal write is involved.
Running records describe the last durable state, not proof of a live process."
  (let ((directory (journal-directory directory name)) (records nil))
    (multiple-value-bind (entries failures) (store:list-private-json directory)
      (dolist (entry entries)
        (handler-case (push (validate-journal (cdr entry) (car entry)) records)
          (error (condition)
            (push (cons (store::record-path directory (car entry)) (princ-to-string condition)) failures))))
      (values (sort records #'< :key (lambda (record) (store:field record "started"))) failures))))

(defun open-job-manager (&key directory (name "server"))
  "Blocking setup/recovery API. Use during startup or off the editor thread.
Acquire exclusive journal ownership; mark prior active records interrupted. Never signal stored PIDs."
  (let* ((directory (journal-directory directory name))
         (manager (make-job-manager :directory directory :lease (acquire-lease directory))))
    (handler-case
        (progn
          (dolist (path (uiop:directory-files directory "*.json"))
            (let* ((id (pathname-name path))
                   (record (validate-journal (store:read-private-json directory id) id))
                   (job (historical-job manager record)))
              (setf (gethash id (manager-jobs manager)) job)))
          manager)
      (error (condition) (sb-posix:close (manager-lease manager)) (error condition)))))

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
      (when (manager-closed manager) (error "Job manager is closed"))
      (setf (gethash (%job-id job) (manager-jobs manager)) job)
      (setf (%job-thread job) (bt2:make-thread (lambda () (control-job job))
                                             :name (format nil "Lisp job ~a" (%job-id job)))))
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
  "Blocking orderly teardown for a supervisor: cancel jobs, join controllers, release journal lease."
  (when manager
    (bt2:with-lock-held ((manager-lock manager)) (setf (manager-closed manager) t))
    (dolist (job (list-jobs manager)) (cancel-job job))
    (dolist (job (list-jobs manager))
      (when (%job-thread job) (bt2:join-thread (%job-thread job))))
    (when (manager-lease manager) (sb-posix:close (manager-lease manager)) (setf (manager-lease manager) nil)))
  t)
