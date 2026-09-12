(defpackage :lem-agent/process-tools
  (:use :cl)
  (:local-nicknames (:agent :lem-agent) (:jobs :lem-toolkit/jobs))
  (:export :install-process-tools))
(in-package :lem-agent/process-tools)

(defconstant +output-limit+ 2048)
(defconstant +input-limit+ 4096)

(defun field (object key &optional default) (gethash key object default))
(defun bounded-text-p (value limit &key nonempty)
  (and (stringp value) (or (not nonempty) (plusp (length value)))
       (<= (length value) limit) (not (find #\Null value))
       (<= (length (babel:string-to-octets value :encoding :utf-8)) limit)))

(defun valid-arguments-p (arguments)
  ;; This runs on the session actor. Only bounded JSON inspection is allowed here.
  (and (hash-table-p arguments)
       (loop for key being the hash-keys of arguments
             always (member key '("argv" "cwd" "timeout_ms" "input" "output_limit") :test #'equal))
       (let ((argv (field arguments "argv")))
         (and (vectorp argv) (not (stringp argv)) (<= 1 (length argv) 64)
              (loop for argument across argv
                    for index from 0
                    always (bounded-text-p argument 4096 :nonempty (zerop index)))))
       (bounded-text-p (field arguments "cwd" ".") 4096 :nonempty t)
       (bounded-text-p (field arguments "input" "") +input-limit+)
       (typep (field arguments "timeout_ms" 30000) '(integer 1 300000))
       (typep (field arguments "output_limit" +output-limit+) `(integer 1 ,+output-limit+))))

(defun process-schema ()
  (agent:json-object
   "type" "object" "additionalProperties" yason:false "required" #("argv")
   "properties"
   (agent:json-object
    "argv" (agent:json-object "type" "array" "minItems" 1 "maxItems" 64
                              "items" (agent:json-object "type" "string" "maxLength" 4096)
                              "description" "Literal executable and arguments. No implicit shell; explicit shell invocations require the same approval.")
    "cwd" (agent:json-object "type" "string" "maxLength" 4096 "default" "."
                             "description" "Existing working directory within the session root; relative paths start at that root.")
    "timeout_ms" (agent:json-object "type" "integer" "minimum" 1 "maximum" 300000 "default" 30000)
    "input" (agent:json-object "type" "string" "maxLength" +input-limit+ "default" ""
                               "description" "Public stdin text, retained with tool arguments in agent history. Do not supply credentials.")
    "output_limit" (agent:json-object "type" "integer" "minimum" 1 "maximum" +output-limit+
                                      "default" +output-limit+
                                      "description" "Retained raw bytes per stdout/stderr stream; older output is discarded."))))

(defun working-directory (context requested)
  ;; Native pathname parsing keeps Unix names containing *, ? or brackets literal.
  ;; Filesystem resolution belongs on the tool worker, after approval.
  (let* ((root (truename (sb-ext:parse-native-namestring (agent:operation-root context)
                                                       nil #p"" :as-directory t)))
         (candidate (truename (merge-pathnames
                               (sb-ext:parse-native-namestring requested nil #p"" :as-directory t) root))))
    (unless (and (uiop:directory-pathname-p root) (uiop:directory-pathname-p candidate)
                 (or (equal root candidate) (uiop:subpathp candidate root)))
      (error "Working directory is outside the session root"))
    (uiop:native-namestring candidate)))

(defun process-environment ()
  ;; Tools do not inherit provider API key variables or accept environment overrides.
  ;; Normal Linux applications still receive their user's runtime and agent sockets.
  (loop for entry in (sb-ext:posix-environ)
        for equal = (position #\= entry)
        when (and equal
                  (member (subseq entry 0 equal)
                          '("PATH" "HOME" "USER" "LOGNAME" "LANG" "LC_ALL" "LC_CTYPE"
                            "TERM" "TMPDIR" "XDG_RUNTIME_DIR" "XDG_CONFIG_HOME" "XDG_CACHE_HOME"
                            "XDG_DATA_HOME" "XDG_STATE_HOME" "DISPLAY" "WAYLAND_DISPLAY"
                            "DBUS_SESSION_BUS_ADDRESS" "SSH_AUTH_SOCK" "SSL_CERT_FILE"
                            "SSL_CERT_DIR" "NIX_SSL_CERT_FILE" "NIX_PATH") :test #'equal))
          collect (copy-seq entry)))

(defun short-reason (reason)
  (when reason (subseq reason 0 (min 512 (length reason)))))

(defun process-result (job snapshot)
  (let* ((state (field snapshot "state"))
         (exited (equal state "exited"))
         (result
           (agent:json-object
            "job_id" (jobs:job-id job) "state" state "exit_code" (field snapshot "exit-code")
            "success" (if (and exited (eql 0 (field snapshot "exit-code"))
                               (null (field snapshot "journal-error"))) t yason:false)
            "outcome" (cond (exited "completed")
                            ((member state '("cancelled" "timed-out" "signaled") :test #'equal) "interrupted")
                            (t "unknown"))
            "reason" (short-reason (field snapshot "reason"))
            "journal_error" (short-reason (field snapshot "journal-error"))
            "stdout" (field snapshot "stdout") "stderr" (field snapshot "stderr"))))
    (dolist (channel '("stdout" "stderr"))
      (let ((observed (field snapshot (concatenate 'string channel "-bytes")))
            (retained (field snapshot (concatenate 'string channel "-retained-bytes"))))
        (setf (gethash (concatenate 'string channel "_observed_bytes") result) observed
              (gethash (concatenate 'string channel "_retained_bytes") result) retained
              (gethash (concatenate 'string channel "_truncated") result)
              (if (> observed retained) t yason:false))))
    result))

(defun rejected-result (reason)
  (agent:json-object "job_id" nil "state" "rejected" "success" yason:false
                     "exit_code" nil "outcome" "not-started" "reason" reason
                     "journal_error" nil "stdout" "" "stderr" ""
                     "stdout_observed_bytes" 0 "stdout_retained_bytes" 0 "stdout_truncated" yason:false
                     "stderr_observed_bytes" 0 "stderr_retained_bytes" 0 "stderr_truncated" yason:false))

(defun execute-process (arguments context job-manager)
  (agent:check-operation context)
  (unless (valid-arguments-p arguments)
    (return-from execute-process (rejected-result "Invalid process arguments")))
  (let* ((directory (handler-case (working-directory context (field arguments "cwd" "."))
                      (error () nil)))
         (environment (process-environment)))
    (unless directory
      (return-from execute-process
        (rejected-result "Working directory is not an existing directory within the session root")))
    (agent:check-operation context)
    (let ((job (handler-case
                   (jobs:start-job
                    (coerce (field arguments "argv") 'list) :manager job-manager
                    :owner (format nil "agent:~a:~a:~d" (agent:operation-session-id context)
                                   (agent:operation-turn-id context) (agent:operation-generation context))
                    :directory directory :timeout (/ (field arguments "timeout_ms" 30000) 1000)
                    :input (field arguments "input" "") :environment environment
                    :output-limit (field arguments "output_limit" +output-limit+))
                 (error ()
                   (return-from execute-process
                     (rejected-result "Managed job submission is unavailable")))))
          (result nil))
      (unwind-protect
           (progn
             ;; Register immediately: core schedules this even if interruption won
             ;; between the generation check, job creation and registration.
             (agent:register-cancellation context (lambda () (jobs:cancel-job job)))
             (loop
               (agent:check-operation context)
               (setf result (jobs:wait-job job :timeout 0.05))
               (when result (return)))
             (agent:check-operation context)
             (process-result job result))
        ;; Covers failed registration or any other adapter failure as well as a
        ;; context invalidated before the asynchronous cancellation callback ran.
        (unless result (jobs:cancel-job job))))))

(defun install-process-tools (manager &key job-manager)
  "Register approved literal process execution. Supply a live shared job manager.
No provider, editor, manager lifecycle, filesystem operation or process is started."
  (unless (jobs:job-manager-ready-p job-manager) (error "Process tools require an open job manager"))
  (agent:register-tool manager "run_process" :schema (process-schema)
                       :validate #'valid-arguments-p :permission t
                       :execute (lambda (arguments context)
                                  (execute-process arguments context job-manager)))
  manager)
