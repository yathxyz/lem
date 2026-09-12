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

(defsystem "lem-agent/openrouter"
  :description "Bounded OpenRouter streaming transport using managed Lisp jobs"
  :depends-on ("lem-agent" "lem-toolkit/jobs")
  :components ((:file "openrouter")))

(defsystem "lem-agent/openrouter-tests"
  :depends-on ("lem-agent/openrouter" "rove")
  :components ((:file "tests/openrouter"))
  :perform (test-op (operation component)
             (declare (ignore operation))
             (symbol-call :rove :run component)))
