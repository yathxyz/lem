(require :asdf)
(load (uiop:getenv "LEM_QUICKLISP_SETUP"))
(defparameter *source-root* (pathname (first (uiop:command-line-arguments))))
(asdf:initialize-source-registry `(:source-registry (:tree ,*source-root*) :ignore-inherited-configuration))
(setf asdf:*system-definition-search-functions*
      (cons 'asdf/system-registry:sysdef-source-registry-search
            (remove 'asdf/system-registry:sysdef-source-registry-search asdf:*system-definition-search-functions*)))
(ql:quickload "lem-agent" :silent t)
(unless (uiop:subpathp (truename (asdf:system-source-directory "lem-agent")) (truename *source-root*))
  (error "Crash worker resolved agent code outside the tested checkout"))

(defun durable-marker (path text &key append)
  (with-open-file (out path :direction :output :if-exists (if append :append :supersede)
                           :if-does-not-exist :create)
    (write-line text out) (finish-output out)
    (sb-posix:fsync (sb-sys:fd-stream-fd out))))

(destructuring-bind (root directory phase) (uiop:command-line-arguments)
  (declare (ignore root))
  (let ((manager (lem-agent:make-manager :directory directory)))
    (lem-agent:register-provider
     manager "fake"
     (lambda (request emit context)
       (declare (ignore request emit context))
       (lem-agent:json-object "tool_calls"
                              (vector (lem-agent:json-object "id" "effect-1" "name" "effect"
                                                             "arguments" (lem-agent:json-object))))))
    (lem-agent:register-tool
     manager "effect" :schema (lem-agent:json-object) :validate (constantly t) :permission t
     :execute (lambda (arguments context)
                (declare (ignore arguments context))
                (durable-marker (merge-pathnames "effect.txt" directory) "effect" :append t)
                (loop (sleep 1))))
    (let ((session (lem-agent:create-session manager :provider "fake" :model "fake" :root directory)))
      (lem-agent:await-request (lem-agent:session-ready session))
      (lem-agent:await-request (lem-agent:submit-message session "effect"))
      (let ((decision
              (loop for snapshot = (lem-agent:session-snapshot session)
                    for pending = (find "pending" (gethash "decisions" snapshot)
                                        :key (lambda (item) (gethash "status" item)) :test #'equal)
                    when pending return pending do (sleep 0.01))))
        (when (equal phase "tool")
          (lem-agent:await-request (lem-agent:resolve-decision session (gethash "id" decision) "allow"))
          (loop until (probe-file (merge-pathnames "effect.txt" directory)) do (sleep 0.01)))
        (durable-marker (merge-pathnames "ready.txt" directory) (lem-agent:session-id session))
        (loop (sleep 1))))))
