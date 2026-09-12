(defsystem "lem-toolkit"
  :description "Common Lisp toolkit components")

(defsystem "lem-toolkit/jobs"
  :description "Common Lisp managed external jobs with bounded output and durable results"
  :depends-on ("bordeaux-threads" "babel" "ironclad" "lem-daemon/recovery-store")
  :serial t
  :components ((:file "wire") (:file "jobs") (:static-file "guardian.lisp")))

(defsystem "lem-toolkit/jobs-ui"
  :description "Lem buffer inspection of managed jobs"
  :depends-on ("lem/core" "lem-toolkit/jobs" "lem-daemon/recovery")
  :components ((:file "ui")))

(defsystem "lem-toolkit/jobs-tests"
  :depends-on ("lem-toolkit/jobs" "rove")
  :components ((:file "tests/jobs"))
  :perform (test-op (op c) (declare (ignore op)) (symbol-call :rove :run c)))

(defsystem "lem-toolkit/jobs-ui-tests"
  :depends-on ("lem-toolkit/jobs-ui" "lem-fake-interface" "rove")
  :components ((:file "tests/ui"))
  :perform (test-op (op c) (declare (ignore op)) (symbol-call :rove :run c)))
