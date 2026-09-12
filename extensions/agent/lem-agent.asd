(defsystem "lem-agent"
  :description "Lisp-owned agent sessions, decisions, and turn execution"
  :depends-on ("bordeaux-threads" "lem-daemon/recovery-store")
  :serial t
  :components ((:file "package") (:file "core") (:file "retention")))

(defsystem "lem-agent/tests"
  :depends-on ("lem-agent" "rove")
  :components ((:file "tests/core"))
  :perform (test-op (operation component)
             (declare (ignore operation))
             (symbol-call :rove :run component)))

(defsystem "lem-agent/retention-tests"
  :depends-on ("lem-agent/tests")
  :components ((:file "tests/retention"))
  :perform (test-op (operation component)
             (declare (ignore operation))
             (symbol-call :rove :run component)))

(defsystem "lem-agent/retention-ui"
  :depends-on ("lem-agent/ui")
  :components ((:file "retention-ui")))

(defsystem "lem-agent/retention-ui-tests"
  :depends-on ("lem-agent/retention-ui" "lem-agent/ui/tests")
  :components ((:file "tests/retention-ui"))
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

(defsystem "lem-agent/drafts"
  :description "Private durable agent composer drafts and exact submission reconciliation"
  :depends-on ("lem-agent")
  :components ((:file "drafts")))

(defsystem "lem-agent/drafts/tests"
  :depends-on ("lem-agent/drafts" "rove")
  :components ((:file "tests/drafts"))
  :perform (test-op (operation component)
             (declare (ignore operation))
             (symbol-call :rove :run component)))

(defsystem "lem-agent/ui"
  :description "Disposable native agent views and deliberate asynchronous input"
  :depends-on ("lem-agent/drafts" "lem-daemon/recovery" "lem/core")
  :components ((:file "ui")))

(defsystem "lem-agent/ui/tests"
  :depends-on ("lem-agent/ui" "lem-daemon/recovery" "lem-fake-interface" "rove")
  :components ((:file "tests/ui"))
  :perform (test-op (operation component)
             (declare (ignore operation))
             (symbol-call :rove :run component)))

(defsystem "lem-agent/editor-tools"
  :description "Root-scoped native file inspection and human-reviewed buffer proposals"
  :depends-on ("lem-agent" "lem-buffer-proposals" "babel" "ironclad")
  :serial t
  :components ((:file "file-access") (:file "editor-tools")))

(defsystem "lem-agent/editor-tools-tests"
  :depends-on ("lem-agent/editor-tools" "lem-fake-interface" "rove")
  :components ((:file "tests/editor-tools"))
  :perform (test-op (operation component)
             (declare (ignore operation))
             (symbol-call :rove :run component)))

(defsystem "lem-agent/edit-recovery"
  :description "Historical agent edit inspection and deliberate live-region restaging"
  :depends-on ("lem-agent/ui" "lem-buffer-proposals" "babel")
  :components ((:file "edit-recovery")))

(defsystem "lem-agent/edit-recovery-tests"
  :depends-on ("lem-agent/edit-recovery" "lem-fake-interface" "rove")
  :components ((:file "tests/edit-recovery"))
  :perform (test-op (operation component)
             (declare (ignore operation))
             (symbol-call :rove :run component)))
