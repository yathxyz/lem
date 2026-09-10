(defsystem "lem-buffer-proposals"
  :description "Revision-checked shared proposals for live Lem buffers"
  :depends-on ("lem/core")
  :serial t
  :components ((:file "proposals") (:file "review")))

(defsystem "lem-buffer-proposals/tests"
  :depends-on ("lem-buffer-proposals" "lem-fake-interface" "rove")
  :serial t
  :components ((:file "tests"))
  :perform (test-op (operation component)
             (declare (ignore operation))
             (uiop:symbol-call :rove :run component)))
