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

(defsystem "lem-agent/process-tools"
  :description "Approved managed process tools for native Lisp agent sessions"
  :depends-on ("lem-agent" "lem-toolkit/jobs")
  :components ((:file "process-tools/tools")))

(defsystem "lem-agent/process-tools-tests"
  :depends-on ("lem-agent/process-tools" "rove")
  :components ((:file "process-tools/tests"))
  :perform (test-op (operation component)
             (declare (ignore operation))
             (symbol-call :rove :run component)))

(defsystem "lem-agent/ui"
  :description "Disposable native agent views and deliberate asynchronous input"
  :depends-on ("lem-agent" "lem/core")
  :components ((:file "ui")))

(defsystem "lem-agent/ui/tests"
  :depends-on ("lem-agent/ui" "lem-fake-interface" "rove")
  :components ((:file "tests/ui"))
  :perform (test-op (operation component)
             (declare (ignore operation))
             (symbol-call :rove :run component)))
