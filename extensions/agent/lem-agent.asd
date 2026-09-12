(defsystem "lem-agent"
  :description "Lisp-owned agent sessions, decisions, and turn execution"
  :depends-on ("bordeaux-threads" "lem-daemon/recovery-store")
  :serial t
  :components ((:file "package") (:file "core")))

(defsystem "lem-agent/tests"
  :depends-on ("lem-agent" "rove")
  :components ((:file "tests/core"))
  :perform (test-op (operation component)
             (declare (ignore operation))
             (symbol-call :rove :run component)))
