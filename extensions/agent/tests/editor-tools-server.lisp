(load (merge-pathnames "../../../scripts/recovery-source.lisp" *load-truename*))
(load-recovery-system "lem-daemon")
(load-recovery-system "lem-agent/editor-tools")

(defvar lem-user::*file-tools-manager* nil)
(defvar lem-user::*file-tools-session* nil)
(defvar lem-user::*file-tools-calls* #())

(defun start-file-tools-fixture ()
  (setf lem-user::*file-tools-manager*
        (lem-agent:make-manager :directory (uiop:getenv "LEM_AGENT_FILE_TEST_JOURNAL")))
  (lem-agent/editor-tools:install-editor-tools lem-user::*file-tools-manager*)
  (lem-agent:register-provider
   lem-user::*file-tools-manager* "fake"
   (lambda (request emit context)
     (declare (ignore emit context))
     (if (equal "tool" (gethash "role" (car (last (coerce (gethash "messages" request) 'list)))))
         (lem-agent:json-object "content" "fixture complete")
         (lem-agent:json-object "tool_calls" lem-user::*file-tools-calls*))))
  (setf lem-user::*file-tools-session*
        (lem-agent:create-session lem-user::*file-tools-manager* :provider "fake" :model "fixture"
                                  :root (uiop:getenv "LEM_AGENT_FILE_TEST_ROOT")))
  (lem:add-hook lem:*exit-editor-hook*
                (lambda () (lem-agent:close-manager lem-user::*file-tools-manager*))))

(unless (uiop:getenvp "LEM_AGENT_FILE_WARMUP")
  (lem:main '("--daemon=agent-files-test" "-q" "--eval" "(cl-user::start-file-tools-fixture)")))
