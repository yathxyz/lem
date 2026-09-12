(defpackage :lem-toolkit/tests/jobs
  (:use :cl :rove)
  (:local-nicknames (:jobs :lem-toolkit/jobs) (:store :lem-daemon/recovery-store)))
(in-package :lem-toolkit/tests/jobs)

(deftest basic-job
  (let* ((directory (merge-pathnames (format nil "lem-jobs-test-~a/" (store:new-id)) (uiop:temporary-directory)))
         (manager nil))
    (unwind-protect
         (progn
           (setf manager (jobs:open-job-manager :directory directory))
           (let* ((job (jobs:start-job '("/run/current-system/sw/bin/bash" "-c" "printf hello; printf error >&2; exit 7")
                                       :manager manager :directory "/tmp"))
                  (result (jobs:wait-job job :timeout 10)))
             (ok result)
             (ok (equal "exited" (store:field result "state")))
             (ok (eql 7 (store:field result "exit-code")))
             (ok (equal "hello" (store:field result "stdout")))
             (ok (equal "error" (store:field result "stderr")))
             (ok (not (nth-value 1 (gethash "stdout" (jobs:job-snapshot job :include-output nil)))))
             (ok (equal "human" (jobs:job-owner job)))
             (ok (equal "/tmp" (jobs:job-directory job)))))
      (when manager (jobs:close-job-manager manager))
      (when (probe-file directory) (uiop:delete-directory-tree directory :validate t)))))

(defmacro with-manager ((manager directory) &body body)
  `(let* ((,directory (merge-pathnames (format nil "lem-jobs-test-~a/" (store:new-id)) (uiop:temporary-directory)))
          (,manager (jobs:open-job-manager :directory ,directory)))
     (unwind-protect (progn ,@body)
       (jobs:close-job-manager ,manager)
       (uiop:delete-directory-tree ,directory :validate t))))

(defun launch (manager script &rest options)
  (apply #'jobs:start-job (list "/run/current-system/sw/bin/bash" "-c" script)
         :manager manager :directory "/tmp" options))

(defun wait-until (function &optional (seconds 5))
  (loop repeat (* seconds 100) when (funcall function) return t do (sleep 0.01)))

(deftest concurrent-failure-timeout-and-cancel
  (with-manager (manager directory)
    (let* ((hung (launch manager "sleep 30" :timeout 0.3))
           (failed (jobs:start-job '("/definitely/no/such/command") :manager manager))
           (normal (launch manager "printf responsive")))
      (ok (equal "responsive" (store:field (jobs:wait-job normal :timeout 10) "stdout"))
          "a hanging or failing tool does not block another job")
      (ok (equal "timed-out" (store:field (jobs:wait-job hung :timeout 10) "state")))
      (ok (eql 127 (store:field (jobs:wait-job failed :timeout 10) "exit-code")))
      (ok (search "could not be started" (store:field (jobs:job-result failed) "stderr"))))
    (let ((job (launch manager "sleep 30")))
      (ok (wait-until (lambda () (equal "running" (store:field (jobs:job-snapshot job) "state")))))
      (jobs:cancel-job job)
      (ok (equal "cancelled" (store:field (jobs:wait-job job :timeout 10) "state"))))))

(deftest bounded-output-and-private-stdin
  (with-manager (manager directory)
    (let* ((chunks nil)
           (job (launch manager "cat >/dev/null; printf streamed; printf '\\377\\000'; head -c 200000 /dev/zero >&2"
                        :input "secret-stdin-value" :output-limit 4096
                        :on-output (lambda (job channel bytes)
                                     (declare (ignore job))
                                     (when (eq channel :stdout) (push (copy-seq bytes) chunks))))))
      (let ((result (jobs:wait-job job :timeout 15)))
        (ok (equal "exited" (store:field result "state")))
        (ok (<= (store:field result "stderr-retained-bytes") 4096))
        (ok (= 200000 (store:field result "stderr-bytes")))
        (ok (every (lambda (chunk) (<= (length chunk) 4096)) chunks)))
      (let* ((path (merge-pathnames (format nil "~a.json" (jobs:job-id job)) directory))
             (journal (uiop:read-file-string path)))
        (ok (not (search "secret-stdin-value" journal)) "stdin is never serialized as a launch parameter")
        (ok (not (search (ironclad:byte-array-to-hex-string
                           (lem-toolkit/jobs-wire:utf8 "secret-stdin-value")) journal))
            "private stdin is absent in raw journal form too")
        (ok (search "stdout-hex" journal))))))

(deftest journal-reconciliation-and-lease
  (with-manager (manager directory)
    (ok (jobs:job-manager-ready-p manager))
    (ok (signals (jobs:open-job-manager :directory directory)) "concurrent journal ownership is rejected")
    (let* ((job (launch manager "printf saved")) (result (jobs:wait-job job :timeout 10))
           (id (jobs:job-id job)))
      (ok result)
      (jobs:close-job-manager manager)
      (ok (not (jobs:job-manager-ready-p manager)))
      (setf manager (jobs:open-job-manager :directory directory))
      (ok (equal "saved" (store:field (jobs:job-result (jobs:find-job id manager)) "stdout")))
      (let ((record (store:read-private-json directory id)))
        (setf (gethash "state" record) "running" (gethash "finished" record) 0)
        (store:write-private-json directory id record))
      (jobs:close-job-manager manager)
      (setf manager (jobs:open-job-manager :directory directory))
      (let ((restored (jobs:find-job id manager)))
        (ok (equal "interrupted" (store:field (jobs:job-result restored) "state")))
        (ok (not (jobs:cancel-job restored)) "interrupted historical records cannot signal a PID")))))

(deftest journal-inspection-raw-bytes-and-schema-failures
  (with-manager (manager directory)
    (let* ((job (launch manager "printf '\\377\\000binary'"))
           (result (jobs:wait-job job :timeout 10)) (id (jobs:job-id job))
           (bytes (jobs:job-output-octets job)))
      (ok result)
      (multiple-value-bind (records failures) (jobs:inspect-job-journal :directory directory)
        (ok (= 1 (length records))) (ok (null failures))
        (ok (equal "exited" (store:field (first records) "state")))
        (ok (jobs:job-manager-ready-p manager) "inspection does not acquire or change the live manager lease"))
      (jobs:close-job-manager manager)
      (setf manager (jobs:open-job-manager :directory directory))
      (ok (equalp bytes (jobs:job-output-octets (jobs:find-job id manager))) "malformed UTF-8 and NUL survive raw journal reload")
      (let ((record (store:read-private-json directory id)))
        (setf (gethash "stdout-retained-bytes" record) 0)
        (store:write-private-json directory id record))
      (multiple-value-bind (records failures) (jobs:inspect-job-journal :directory directory)
        (ok (null records)) (ok (= 1 (length failures)) "inconsistent output counts are rejected before trusted use"))
      (jobs:close-job-manager manager)
      (ok (signals (jobs:open-job-manager :directory directory)) "malformed journal fails initialization without replay"))))

(deftest literal-argv-and-consumer-failure
  (with-manager (manager directory)
    (let* ((job (jobs:start-job '("/run/current-system/sw/bin/printf" "%s" "$(touch /tmp/not-executed); literal")
                                 :manager manager))
           (result (jobs:wait-job job :timeout 10)))
      (ok (equal "$(touch /tmp/not-executed); literal" (store:field result "stdout"))
          "arguments have literal, not shell, semantics"))
    (let* ((job (launch manager "printf trigger; sleep 30"
                        :on-output (lambda (&rest ignored) (declare (ignore ignored)) (error "consumer broke"))))
           (result (jobs:wait-job job :timeout 10)))
      (ok (equal "failed" (store:field result "state")))
      (ok (search "consumer" (store:field result "reason"))))))

(defun process-running-p (pid)
  (let ((path (format nil "/proc/~d/stat" pid)))
    (when (probe-file path)
      (let* ((text (uiop:read-file-string path)) (end (position #\) text :from-end t)))
        (not (find (char text (+ end 2)) "ZX"))))))

(defun process-parent-pid (pid)
  (let* ((text (uiop:read-file-string (format nil "/proc/~d/stat" pid)))
         (end (position #\) text :from-end t)))
    (parse-integer (second (uiop:split-string (subseq text (+ end 2)))))))

(deftest guardian-and-watchdog-failures-clean-descendants
  (with-manager (manager directory)
    (dolist (failure '(:guardian :watchdog))
      (let* ((parent-path (merge-pathnames (format nil "parent-~a.pid" failure) directory))
             (child-path (merge-pathnames (format nil "child-~a.pid" failure) directory))
             (job (launch manager (format nil "printf '%s' $$ > ~a; sleep 30 & printf '%s' $! > ~a; wait"
                                          (namestring parent-path) (namestring child-path)))))
        (ok (wait-until (lambda () (ignore-errors (parse-integer (uiop:read-file-string child-path))))))
        (let* ((parent (parse-integer (uiop:read-file-string parent-path)))
               (child (parse-integer (uiop:read-file-string child-path)))
               (anchor (process-parent-pid parent))
               (watchdog (process-parent-pid anchor))
               (guardian (process-parent-pid watchdog)))
          (ok (and (= (sb-posix:getpgid parent) anchor)
                   (/= (sb-posix:getpgid watchdog) anchor)
                   (/= (sb-posix:getpgid guardian) anchor))
              "target group has a pinned anchor and two outside supervisors")
          ;; All PIDs come from this live fixture's verified process tree, never
          ;; from a durable journal or a caller-supplied cancellation target.
          (sb-posix:kill (ecase failure (:guardian guardian) (:watchdog watchdog)) sb-posix:sigkill)
          (let ((result (jobs:wait-job job :timeout 10)))
            (ok (equal "failed" (store:field result "state"))))
          (ok (wait-until (lambda () (not (process-running-p child))))
              (format nil "~a failure cleans target descendants" failure)))))))

(deftest cleanup-descendants-and-unread-stdin
  (with-manager (manager directory)
    (dolist (finish '("cancel" "timeout" "normal"))
      (let* ((pid-path (merge-pathnames (format nil "child-~a.pid" finish) directory))
             (script (format nil "sleep 30 & printf '%s' $! > ~a; ~a"
                             (namestring pid-path) (if (equal finish "normal") "exit 0" "wait")))
             (job (launch manager script :timeout (if (equal finish "timeout") 0.3 10))))
        (ok (wait-until (lambda () (probe-file pid-path))) "spawned descendant published its PID")
        (let ((pid (parse-integer (uiop:read-file-string pid-path))))
          (when (equal finish "cancel") (jobs:cancel-job job))
          (ok (jobs:wait-job job :timeout 12))
          (ok (wait-until (lambda () (not (process-running-p pid))))
              (format nil "~a cleans descendants in the owned process group" finish)))))
    (let* ((job (launch manager "sleep 30" :input (make-string (* 512 1024) :initial-element #\x) :timeout 0.2))
           (result (jobs:wait-job job :timeout 10)))
      (ok (equal "timed-out" (store:field result "state")))
      (ok (not (search "xxxxxxxxxxxxxxxx" (uiop:read-file-string
                                            (merge-pathnames (format nil "~a.json" (jobs:job-id job)) directory))))
          "a tool refusing stdin cannot block timeout or persist the input"))))


(deftest stopped-parent-and-stopped-group-remain-cancellable
  (with-manager (manager directory)
    (dolist (target '("parent" "group"))
      (dolist (finish '("cancel" "timeout"))
        (let* ((path (merge-pathnames (format nil "stopped-~a-~a.pid" target finish) directory))
               (job (launch manager
                            (format nil "printf '%s' $$ > ~a; kill -STOP ~a; while :; do :; done"
                                    (namestring path) (if (equal target "parent") "$PPID" "0"))
                            :timeout (if (equal finish "timeout") 0.5 10))))
          (ok (wait-until (lambda () (ignore-errors (parse-integer (uiop:read-file-string path))))))
          (let ((pid (parse-integer (uiop:read-file-string path))))
            (ok (wait-until
                 (lambda ()
                   (let* ((stopped (if (equal target "parent") (process-parent-pid pid) pid))
                          (stat (uiop:read-file-string (format nil "/proc/~d/stat" stopped))))
                     (char= #\T (char stat (+ 2 (position #\) stat :from-end t)))))))
                "fixture reached the stopped state before the recovery action")
            (when (equal finish "cancel") (jobs:cancel-job job))
            (let ((result (jobs:wait-job job :timeout 12)))
              (ok (equal (if (equal finish "cancel") "cancelled" "timed-out")
                         (store:field result "state"))))
            (ok (wait-until (lambda () (not (process-running-p pid))))
                (format nil "~a works when target stops ~a" finish target))))))))

(deftest target-environment-does-not-configure-supervisors
  (with-manager (manager directory)
    (let* ((job (launch manager "printf '%s' \"$PRIVATE_JOB_TOKEN\"; printf '%s' \"$SBCL_HOME\""
                        :environment '("PRIVATE_JOB_TOKEN=private-env-token" "PATH="
                                       "UNUSED_JOB_SECRET=unprinted-private-environment-value"
                                       "SBCL_HOME=/definitely/no/sbcl/core"
                                       "LD_PRELOAD=/definitely/no/preload.so")))
           (result (jobs:wait-job job :timeout 10))
           (record (store:read-private-json directory (jobs:job-id job))))
      (ok (equal "exited" (store:field result "state")))
      (ok (eql 0 (store:field result "exit-code")))
      (ok (search "private-env-token/definitely/no/sbcl/core" (store:field result "stdout")))
      (ok (not (gethash "environment" record)))
      (ok (not (search "unprinted-private-environment-value" (uiop:read-file-string
                                            (merge-pathnames (format nil "~a.json" (jobs:job-id job)) directory))))))))


(deftest escaped-output-writer-is-an-explicit-incomplete-result
  (with-manager (manager directory)
    (let* ((path (merge-pathnames "escaped.pid" directory))
           (job (launch manager
                        (format nil "/run/current-system/sw/bin/setsid /run/current-system/sw/bin/bash -c 'printf %s $$ > ~a; sleep 2' & while ! test -s ~a; do :; done; exit 0"
                                (namestring path) (namestring path))))
           (result (jobs:wait-job job :timeout 10)))
      (ok (equal "failed" (store:field result "state")))
      (ok (search "Output drain incomplete" (store:field result "reason")))
      ;; A deliberately detached process is outside the ownership contract. This
      ;; bounded fixture exits itself; do not adopt its PID as a cancellation ID.
      (let ((pid (parse-integer (uiop:read-file-string path))))
        (ok (wait-until (lambda () (not (process-running-p pid)))))))))
