(defpackage :lem-agent/retention-tests
  (:use :cl :rove)
  (:local-nicknames (:agent :lem-agent) (:store :lem-daemon/recovery-store)
                    (:fixture :lem-agent/tests)))
(in-package :lem-agent/retention-tests)

(defun field (object name) (gethash name object))
(defun capacity (manager name) (field (agent:session-capacity manager) name))
(defun fingerprint (manager session)
  (nth-value 1 (agent:inspect-session-journal manager (agent:session-id session))))
(defun discard (manager session)
  (agent:discard-session-journal manager (agent:session-id session) (fingerprint manager session)
                                 :acknowledge-uncertain t))

(deftest atomic-session-admission-and-explicit-release
  (fixture::with-manager (manager directory)
    (setf (agent::manager-maximum-sessions manager) 2)
    (let ((sessions nil) (failures 0) (lock (bt2:make-lock)))
      (let ((threads
              (loop repeat 8 collect
                (bt2:make-thread
                 (lambda ()
                   (handler-case
                       (let ((session (fixture::new-session manager directory)))
                         (bt2:with-lock-held (lock) (push session sessions)))
                     (agent::agent-budget-exceeded () (bt2:with-lock-held (lock) (incf failures)))))))))
        (dolist (thread threads) (bt2:join-thread thread)))
      (ok (= 2 (length sessions) (capacity manager "loaded") (capacity manager "reserved")))
      (ok (= 6 failures))
      (let ((session (first sessions)))
        (ok (signals (discard manager session)) "idle actors must be explicitly closed")
        (fixture::await (agent:close-session session))
        (ok (discard manager session))
        (ok (null (agent:find-session manager (agent:session-id session))))
        (ok (signals (fixture::await (agent:submit-message session "old handle")))))
      (ok (fixture::new-session manager directory))
      (ok (= 2 (capacity manager "reserved"))))))

(deftest journal-fingerprint-refuses-changed-content
  (fixture::with-manager (manager directory)
    (let* ((session (fixture::new-session manager directory))
           (before (fingerprint manager session)))
      (fixture::await (agent:close-session session))
      (ok (signals (agent:discard-session-journal manager (agent:session-id session) before)))
      (ok (= 1 (capacity manager "reserved")))
      (ok (discard manager session))
      (ok (signals (agent:inspect-session-journal manager (agent:session-id session)))))))

(deftest bounded-startup-and-inert-overflow-inventory
  (fixture::with-manager (manager directory)
    (let ((ids (loop repeat 4 collect (agent:session-id (fixture::new-session manager directory)))))
      (agent:close-manager manager :wait t)
      (let ((small (agent:make-manager :directory directory :maximum-sessions 2)))
        (unwind-protect
             (multiple-value-bind (sessions errors) (agent:restore-sessions small)
               (mapc (lambda (session) (fixture::await (agent:session-ready session))) sessions)
               (ok (= 2 (length sessions))) (ok errors)
               (ok (= 4 (capacity small "reserved")))
               (ok (= 2 (capacity small "unloaded")))
               (ok (signals (fixture::new-session small directory)))
               (let ((seen nil) (cursor nil))
                 (loop
                   (multiple-value-bind (page next total) (agent:list-session-journals small :after cursor :limit 1)
                     (ok (= 4 total))
                     (unless page (return))
                     (push (field (first page) "id") seen) (setf cursor next)))
                 (ok (equal (sort seen #'string<) (sort (copy-list ids) #'string<))))
               (let ((unloaded (find-if-not (lambda (id) (agent:find-session small id)) ids)))
                 (multiple-value-bind (record stamp diagnostic) (agent:inspect-session-journal small unloaded)
                   (ok (null diagnostic)) (ok (equal "idle" (field record "status")))
                   (ok (null (agent:find-session small unloaded)) "inspection cannot attach an actor")
                   (ok (agent:discard-session-journal small unloaded stamp))
                   (ok (= 3 (capacity small "reserved"))))))
          (agent:close-manager small :wait t))))))

(deftest malformed-content-is-inspectable-and-exactly-discardable
  (fixture::with-manager (manager directory)
    (let ((session (fixture::new-session manager directory)))
      (fixture::await (agent:close-session session))
      (let ((path (store::record-path directory (agent:session-id session))))
        (with-open-file (out path :direction :output :if-exists :supersede)
          (write-string "{broken" out))
        (multiple-value-bind (record stamp diagnostic) (agent:inspect-session-journal manager (agent:session-id session))
          (ok (null record)) (ok diagnostic) (ok (= 64 (length stamp)))
          (ok (signals (agent:discard-session-journal manager (agent:session-id session) stamp)))
          (ok (agent:discard-session-journal manager (agent:session-id session) stamp :acknowledge-uncertain t)))))))

(deftest uncertain-initial-write-keeps-admission-reserved
  (fixture::with-manager (manager directory)
    (setf (agent::manager-maximum-sessions manager) 1)
    (let ((original (symbol-function 'store:write-private-json)) (session nil))
      (unwind-protect
           (progn
             (setf (symbol-function 'store:write-private-json)
                   (lambda (&rest args) (apply original args) (error "Injected post-publication failure")))
             (setf session (agent:create-session manager :provider "fake" :model "fake" :root directory))
             (ok (signals (fixture::await (agent:session-ready session))))
             (ok (signals (fixture::new-session manager directory)))
             (ok (= 1 (capacity manager "reserved"))))
        (setf (symbol-function 'store:write-private-json) original))
      (fixture::await (agent:close-session session))
      (ok (discard manager session)))))

(deftest surviving-workers-protect-their-session-slot
  (fixture::with-manager (manager directory)
    (let ((gate (fixture::make-gate)) (entered nil))
      (agent:register-provider manager "fake"
                               (lambda (&rest args) (declare (ignore args))
                                 (setf entered t) (fixture::wait-gate gate)
                                 (agent:json-object "content" "late")))
      (let ((session (fixture::new-session manager directory)))
        (unwind-protect
             (progn
               (fixture::await (agent:submit-message session "wait"))
               (fixture::wait-for (lambda () entered))
               (fixture::await (agent:close-session session))
               (ok (signals (discard manager session)))
               (ok (= 1 (capacity manager "reserved")))
               (fixture::open-gate gate)
               (dolist (worker (agent::session-workers session)) (bt2:join-thread (car worker)))
               (ok (discard manager session)))
          (fixture::open-gate gate))))))

(deftest maintenance-retains-lease-without-blocking-ui-lookups
  (fixture::with-manager (manager directory)
    (let* ((session (fixture::new-session manager directory))
           (gate (fixture::make-gate)) (entered nil) (failure nil)
           (original (symbol-function 'store::fsync-directory)) (thread nil))
      (fixture::await (agent:close-session session))
      (let ((stamp (fingerprint manager session)))
        (unwind-protect
             (progn
               (setf (symbol-function 'store::fsync-directory)
                     (lambda (path)
                       (when (equal path directory) (setf entered t) (fixture::wait-gate gate))
                       (funcall original path)))
               (setf thread
                     (bt2:make-thread
                      (lambda () (handler-case (agent:discard-session-journal manager (agent:session-id session) stamp)
                                   (error (condition) (setf failure condition))))))
               (fixture::wait-for (lambda () entered))
               (ok (agent:manager-open-p manager))
               (ok (eq session (agent:find-session manager (agent:session-id session))))
               (ok (= 1 (capacity manager "reserved")))
               (agent:close-manager manager)
               (ok (signals (agent:make-manager :directory directory)) "lease survives an outstanding deletion fsync")
               (fixture::open-gate gate) (bt2:join-thread thread)
               (ok (null failure))
               (agent:close-manager manager :wait t)
               (let ((reopened (agent:make-manager :directory directory)))
                 (unwind-protect (ok (= 0 (capacity reopened "reserved")))
                   (agent:close-manager reopened :wait t))))
          (fixture::open-gate gate)
          (setf (symbol-function 'store::fsync-directory) original)
          (when thread (bt2:join-thread thread)))))))

(deftest failed-deletion-fsync-requires-exact-retry
  (fixture::with-manager (manager directory)
    (let* ((session (fixture::new-session manager directory))
           (other (fixture::new-session manager directory))
           (original (symbol-function 'store::fsync-directory)))
      (fixture::await (agent:close-session session))
      (fixture::await (agent:close-session other))
      (let ((stamp (fingerprint manager session)))
        (unwind-protect
             (progn
               (setf (symbol-function 'store::fsync-directory)
                     (lambda (path) (if (equal path directory) (error "Injected deletion fsync failure")
                                        (funcall original path))))
               (ok (signals (agent:discard-session-journal manager (agent:session-id session) stamp))))
          (setf (symbol-function 'store::fsync-directory) original))
        (ok (= 2 (capacity manager "reserved")))
        (ok (equal (agent:session-id session) (capacity manager "pending_cleanup")))
        (ok (signals (fixture::new-session manager directory)))
        (ok (signals (discard manager other)))
        (multiple-value-bind (record same-stamp diagnostic) (agent:inspect-session-journal manager (agent:session-id session))
          (ok (null record)) (ok diagnostic) (ok (equal stamp same-stamp))
          (setf (char same-stamp 0) (if (char= #\0 (char same-stamp 0)) #\1 #\0))
          (ok (equal stamp (nth-value 1 (agent:inspect-session-journal manager (agent:session-id session))))))
        (ok (agent:discard-session-journal manager (agent:session-id session) stamp))
        (ok (= 1 (capacity manager "reserved")))
        (ok (null (capacity manager "pending_cleanup")))
        (ok (discard manager other))))))

(deftest examination-budget-counts-malformed-records
  (fixture::with-manager (manager directory)
    (let ((ids (loop repeat 4 collect (agent:session-id (fixture::new-session manager directory)))))
      (agent:close-manager manager :wait t)
      (dolist (id ids) (store:write-private-json directory id (agent:json-object "broken" t)))
      (let ((small (agent:make-manager :directory directory :maximum-sessions 2))
            (original (symbol-function 'store:read-private-json)) (reads 0))
        (unwind-protect
             (progn
               (setf (symbol-function 'store:read-private-json)
                     (lambda (&rest arguments) (incf reads) (apply original arguments)))
               (multiple-value-bind (sessions errors) (agent:restore-sessions small)
                 (ok (null sessions)) (ok errors) (ok (= 2 reads))
                 (ok (= 4 (capacity small "unloaded") (capacity small "reserved")))))
          (setf (symbol-function 'store:read-private-json) original)
          (agent:close-manager small :wait t))))))

(deftest failed-thread-launch-does-not-leak-an-unwritten-slot
  (fixture::with-manager (manager directory)
    (let ((original (symbol-function 'bt2:make-thread)))
      (unwind-protect
           (progn
             (setf (symbol-function 'bt2:make-thread)
                   (lambda (function &rest args)
                     (if (equal "agent session actor" (getf args :name)) (error "Injected thread creation failure")
                         (apply original function args))))
             (ok (signals (fixture::new-session manager directory))))
        (setf (symbol-function 'bt2:make-thread) original))
      (ok (= 0 (capacity manager "reserved") (capacity manager "loaded")))
      (ok (fixture::new-session manager directory)))))

(deftest unknown-unretained-tool-outcomes-require-acknowledgement
  (dolist (close-active '(nil t))
    (fixture::with-manager (manager directory)
      (let ((gate (fixture::make-gate)) (entered nil))
        (agent:register-provider manager "fake"
                                 (fixture::tool-provider (vector (fixture::tool-call "run_process"))))
        (agent:register-tool manager "run_process" :schema (agent:json-object) :validate (constantly t)
                             :execute (lambda (&rest args) (declare (ignore args))
                                        (setf entered t) (when close-active (fixture::wait-gate gate))
                                        (agent:json-object "error" "external outcome uncertain" "outcome" "unknown")))
        (let ((session (fixture::new-session manager directory)))
          (unwind-protect
               (progn
                 (fixture::await (agent:submit-message session "effect"))
                 (fixture::wait-for (lambda () entered))
                 (unless close-active (fixture::idle session))
                 (fixture::await (agent:close-session session))
                 (fixture::open-gate gate)
                 (dolist (worker (agent::session-workers session)) (bt2:join-thread (car worker)))
                 (let ((stamp (fingerprint manager session)))
                   (ok (signals (agent:discard-session-journal manager (agent:session-id session) stamp)))
                   (ok (agent:discard-session-journal manager (agent:session-id session) stamp
                                                      :acknowledge-uncertain t))))
            (fixture::open-gate gate)))))))
